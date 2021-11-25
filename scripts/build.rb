#!/usr/bin/ruby

require 'yaml'
require 'optparse'
require 'fileutils'
require 'erb'
require 'etc'

COMPRESSION=19

#--------------------------

module Helpers
  def run(cmd)
    if cmd.is_a?(Array)
      cmd.each { |c| run(c) }
    else
      system(cmd) || raise("error running command: #{cmd}")
    end
  end

  def write_template(template, dst, cfg)
    if File.file?(template)
      ErbContext.new(cfg).write(template, dst)
      return
    end

    Dir.children(template).sort.each do |base|
      src = File.join(template, base)
      if '.clean' == base
        Dir.glob(File.join(dst, '*')).each { |d| FileUtils.rm_rf(d) }
      else
        FileUtils.mkdir_p(dst)
        ndst = File.join(dst, base)
        if File.directory?(src)
          write_template(src, ndst, cfg)
        else
          if base.end_with?('.erb')
            ndst = ndst[0..-5]
            ErbContext.new(cfg).write(src, ndst)
          else
            FileUtils.cp(src, dst)
          end
        end
      end
    end
  end
end

include Helpers

#--------------------------

def sync_repo(repo, repos)
  repo = File.join(repo, 'repos')
  FileUtils.mkdir_p(repo)

  tmp = File.join(BUILD_DIR, 'tmp')
  conf_dir = "#{tmp}/etc/portage/repos.conf"
  FileUtils.rm_rf(tmp)
  FileUtils.mkdir_p(conf_dir)

  erb = ErbContext.new({ "repository" => repo })
  Dir.glob(File.join(CONF_DIR, 'repos-sync/*')) do |f|
    erb.write(f, File.join(conf_dir, File.basename(f)))
  end

  FileUtils.ln_s("#{repo}/gentoo/profiles/default", "#{tmp}/etc/portage/make.profile")

  run("PORTAGE_CONFIGROOT=#{tmp} emerge --sync #{repos}")

  Dir.children(repo).each do |name|
    o = File.join(repo, name)
    if File.exist?(File.join(o, '.git')) || File.exist?(File.join(o, '.hg'))
      run("touch #{File.join(o, 'metadata', 'timestamp.chk')}")
    end
  end

  kernel_repo = File.join(repo, 'kernel')
  unless File.exist?(kernel_repo)
    write_template(File.join(CONF_DIR, 'kernel', 'repo'), kernel_repo, {})
  end

  FileUtils.rm_rf(tmp)
end

#--------------------------

class Builder
  include Helpers

  def initialize(arch, cfg)
    raise "no arch found: #{arch}" unless cfg['archs'].has_key?(arch)
    cfg = cfg.merge(cfg['archs'][arch])
    cfg['arch'] = arch
    cfg['cores'] = CORES

    @cfg = cfg
    @arch = cfg['arch']
    @gentoo = File.join(BUILD_DIR, @arch)
    @repo = cfg['repository']
  end

  def drop_package(name)
    puts "Dropping binary packages for #{@arch}"

    dst = "#{@repo}/packages/#{@arch}"

    Dir.glob(File.join(dst, "#{name}*")) do |f|
      puts "- removing #{File.basename(File.dirname(f))}/#{File.basename(f)}"
      FileUtils.rm(f)
    end

    run("PKGDIR=#{dst} emaint binhost --fix")
  end

  def exec(cmd)
    puts "Executing action for #{@arch}"

    mounted do
      chrun(cmd)
    end
  end

  def apply
    puts "Applying tarball and binary packages for #{@arch}"

    ok = false

    ['stage3', 'stage4'].each do |stage|
      src = tarball(stage)
      if File.exist?(src)
        puts "Copying #{stage} tarball"
        ok = true
        ['zst', 'xz', 'bz2'].each { |ext| FileUtils.rm_rf(repo_tarball(stage, ext)) }
        FileUtils.mv(src, repo_tarball(stage))
      end
    end

    src = File.join(@gentoo, 'var/cache/binpkgs')
    if File.exist?(src) && File.exist?(File.join(src, 'Packages'))
      puts 'Copying binpkgs'
      ok = true
      dst = "#{@repo}/packages/#{@arch}"
      run [
        "rsync --delete -a -W #{src}/ #{dst}",
        "PKGDIR=#{dst} emaint binhost --fix"
      ]
    end

    src = File.join(@gentoo, 'var/cache/genkernel')
    if File.exist?(src)
      ok = true
      dst = File.join(@repo, 'genkernel', @arch)
      FileUtils.mkdir_p(dst)
      FileUtils.rm_rf(Dir.glob("#{dst}/*"))
      FileUtils.cp_r(Dir.glob("#{src}/*"), dst)
    end

    if ok
      puts 'Done'
    else
      puts 'Nothing to apply'
    end
  end

  def build(phases)
    if phases.include?(:init)
      puts "Preparing - cleanup"
      cleanup

      puts "Unpacking stage3 tarball"
      unpack_tarball

      puts "Configuring"
      configure(true)

      puts "Copying binary packages"
      copy_binpkgs

      check_profile
    else
      umount
    end

    if phases.include?(:stage3) || phases.include?(:stage3_build)
      puts "Building stage3"
      build_stage3
    end

    if phases.include?(:stage3) || phases.include?(:stage3_pack)
      puts "Creating stage3 tarball"
      create_stage3
    end

    if @cfg['kernel']
      if phases.include?(:kernel)
        puts "Checking if we need to build new kernel"
        if kernel_check
          puts "- latest kernel available"
        else
          phases += [:kernel_init, :kernel_build]
        end
      end

      if phases.include?(:kernel_init)
        puts "Preparing kernel build environment"
        kernel_init
      end

      if phases.include?(:kernel_build)
        puts "Building kernel"
        kernel_build
      end
    end

    if phases.include?(:stage4) || phases.include?(:stage4_build)
      puts "Building stage4"
      build_stage4
    end

    if phases.include?(:stage4) || phases.include?(:stage4_pack)
      puts "Creating stage4 tarball"
      create_stage4
    end

    if phases.include?(:binpkgs)
      puts "Building other binary packages"
      build_world(@cfg[@cfg['pkgs_all']], true)
    end

    puts "Finished"
  end

  def kernel_check
    mounted do
      version = kernel_version
      File.exist?(File.join(@repo, 'kernel', @arch, "kernel-gentoo-#{@arch}-bin-#{version}.tar.xz"))
    end
  end

  def kernel_version
      version = do_chroot do
        `emerge -qp "=gentoo-sources-#{@cfg['kernel']}*"`
      end

      m = /gentoo-sources-([^ ]+)/.match(version)
      raise "can't parse kernel version: #{version}" if m.nil?

      version = m[1]
      puts "- version is: #{version}"

      version
  end

  def kernel_builder
    builder = self.clone
    def builder.set_kernel_vars
      @orig_gentoo = @gentoo
      @gentoo = "#{@gentoo}-kernel"
    end
    builder.set_kernel_vars
    builder
  end

  def kernel_init
    pkgs = @cfg['kernel_build_pkgs']
    unless pkgs.nil?
      mounted do
        chrun "emerge -q1u #{pkgs.join(' ')}"
      end
    end
    kernel_builder.kernel_init_impl
  end

  def kernel_init_impl
    cleanup
    run("cp -a --reflink=auto #{@orig_gentoo} #{@gentoo}")
  end

  def kernel_build
    kernel_builder.kernel_build_impl
    mounted do
      chrun('emerge --sync kernel')
    end
  end

  def kernel_build_impl
    configure(true)

    initramfs = @cfg['initramfs']
    FileUtils.cp(conf_path('kernel/genkernel.conf'), File.join(@gentoo, 'etc/genkernel.conf')) if initramfs

    mounted do
      version = kernel_version

      m = /([^-]+)(-r.*)?/.match(version)
      kver_l = "#{m[1]}-gentoo#{m[2] || ''}"

      chrun(%{emerge -q1u "=gentoo-sources-#{version}"})
      chrun("eselect kernel set linux-#{kver_l}")

      kver = File.basename(File.readlink(File.join(@gentoo, 'usr/src/linux')))
      m = /linux-(.*)-gentoo(.*)/.match(kver)
      raise "can't parse version: #{kver}" if m.nil?
      kver = "#{m[1]}#{m[2]}"
      raise "version mismatch: #{version} / #{kver}" unless version == kver

      kernel = "kernel-#{@cfg['os_arch']}-#{@cfg['kernel']}.config"
      FileUtils.cp(conf_path('kernel', kernel), File.join(@gentoo, 'usr/src/linux/.config'))

      kernel_config = @cfg['kernel_config']
      unless kernel_config.nil?
        chrun [
          'scripts/config -d CONFIG_GENERIC_CPU',
          'scripts/config -d CONFIG_MNATIVE',
          "scripts/config -e CONFIG_#{kernel_config}"
        ], '/usr/src/linux'
      end

      if initramfs
        version = do_chroot do
          run('emerge -q1u sys-kernel/genkernel')
          `genkernel --version`
        end.strip

        cache = File.join(@repo, 'genkernel', @arch, version)
        if File.exist?(cache)
          puts "Found genkernel cache"
          dst = File.join(@gentoo, 'var/cache/genkernel')
          FileUtils.rm_rf(Dir.glob("#{dst}/*"))
          FileUtils.mkdir_p(dst)
          FileUtils.cp_r(cache, dst)
        end
      end

      chrun [
        "make -j#{CORES}",
        'make modules_install',
        @cfg['kernel_dtbs'] ? 'DTC_FLAGS="-@" make dtbs && make dtbs_install' : [],
        'make install',
      ], '/usr/src/linux'

      if @cfg['kernel_pkgs']
        pkgs = @cfg['kernel_pkgs']
        pkgs = pkgs.flatten.uniq.join(' ') if pkgs.is_a?(Array)
        chrun("emerge -q1 #{pkgs}")
      end

      chrun('genkernel initramfs', '/usr/src/linux') if initramfs

      name = "kernel-gentoo-#{@arch}-bin-#{kver}.tar.xz"
      local_tarball = "#{@gentoo}/var/cache/distfiles/#{name}"
      pack = "tar -cJpf #{local_tarball} -C #{@gentoo}"
      pack = "#{pack} boot/config-#{kver_l} boot/System.map-#{kver_l} boot/vmlinuz-#{kver_l} lib/modules/#{kver_l}"
      pack = "#{pack} boot/initramfs-#{kver_l}.img" if initramfs
      pack = "#{pack} boot/dtbs/#{kver_l}" if @cfg['kernel_dtbs']
      run(pack)

      ebuild_dir = File.join(@gentoo, "var/db/repos/kernel/sys-kernel/gentoo-#{@arch}-bin")
      FileUtils.mkdir_p(ebuild_dir)
      ebuild = File.join(ebuild_dir, "gentoo-#{@arch}-bin-#{kver}.ebuild")
      write_template(conf_path('kernel', 'gentoo-bin.ebuild.erb'), ebuild, @cfg)
      chrun("ebuild --force /var/db/repos/kernel/sys-kernel/gentoo-#{@arch}-bin/gentoo-#{@arch}-bin-#{kver}.ebuild digest")

      dst = File.join(@repo, 'repos', 'kernel', 'sys-kernel', "gentoo-#{@arch}-bin")
      FileUtils.mkdir_p(dst)
      FileUtils.cp_r("#{ebuild_dir}/.", dst)
      FileUtils.touch(File.join(@repo, 'repos', 'kernel', 'metadata', 'timestamp.chk'))

      FileUtils.mkdir_p(File.join(@repo, 'kernel', @arch))
      FileUtils.cp(local_tarball, File.join(@repo, 'kernel', @arch, name))
    end
  end

  def shell(is_kernel)
    if is_kernel
      kernel_builder.shell(false)
    else
      mounted do
        chrun('/bin/bash', '/root')
      end
    end
  end

  def build_world(pkgs, clean)
    pkgs = pkgs.flatten.uniq.sort
    File.open(File.join(@gentoo, 'var/lib/portage/world'), 'w') do |f|
      pkgs.each { |p| f.puts(p) }
    end

    configure(true)

    mounted do
      chrun [
        'env-update',
        'emerge -qDuN @world --with-bdeps=y --changed-deps=y --complete-graph=y --keep-going || emerge -qDuN @world --with-bdeps=y --changed-deps=y --complete-graph=y --keep-going',
        'emerge -q @preserved-rebuild',
        'emerge -q --depclean',
        'etc-update --automode -5',
        clean ? 'eclean packages' : [],
        'eselect news read'
      ]
    end
  end

  def tarball(name)
    File.join(BUILD_DIR, "#{name}-#{@arch}-latest.tar.zst")
  end

  def create_stage3
    configure(false)
    run("tar -C #{@gentoo} --exclude var/cache/* --exclude var/db/repos -cp . | zstd -#{COMPRESSION} -T0 > #{tarball('stage3')}")
  end

  def create_stage4
    configure(false)
    run("tar -C #{@gentoo} --exclude var/cache/* -cp . | zstd -#{COMPRESSION} -T0 > #{tarball('stage4')}")
  end

  def build_stage3
    mounted do
      puts 'Updating portage tree'
      chrun [
        'env-update',
        'emerge -q --sync',
        'env-update'
      ]

      puts 'Updating gcc'
      chrun [
        'emerge -q1u gcc binutils glibc',
        'emerge -q --prune gcc binutils glibc',
        'env-update'
      ]

      puts 'Updating portage'
      chrun [
        'emerge -q1u portage'
      ]

      puts 'Updating system'
      chrun [
        'emerge -qe @system --keep-going --with-bdeps=y',
        'emerge -q1u sys-fs/udev sys-apps/systemd-tmpfiles', # remove after migration
        'emerge -q --depclean',
        'etc-update --automode -5',
        'eselect news read',
      ]

      puts 'Cleanup stage3'
      chrun [
        'emerge -q --depclean'
      ]
    end
  end

  def build_stage4
    build_world(@cfg[@cfg['pkgs_stage4']], false)

    if @cfg['kernel']
      mounted do
        chrun("FEATURES='-buildpkg' emerge -q sys-kernel/gentoo-#{@arch}-bin")
      end
    end
  end

  def get_profile(pp)
    pl = File.readlink(pp)

    m = /(.*)\/profiles\/(.*)/.match(pl)

    return m[1], m[2]
  end

  def check_profile
    pp = File.join(@gentoo, 'etc/portage/make.profile')
    base, profile = get_profile(pp)

    d_profile = @cfg['profile']
    d_base = '../../var/db/repos/gentoo'

    if "#{profile}/desktop/plasma" == d_profile
      FileUtils.ln_s("#{d_base}/profiles/#{d_profile}", pp, force: true)
      base, profile = get_profile(pp)
    end

    raise "profile is not supported: #{profile}, probably need migration" unless profile == d_profile

    unless base == d_base
      puts "Fixing profile path from #{base} to #{d_base}"
      FileUtils.ln_s("#{d_base}/profiles/#{profile}", pp, force: true)
    end
  end

  def copy_binpkgs
    binpkgs = File.join(@gentoo, 'var/cache/binpkgs')
    FileUtils.mkdir_p(binpkgs)
    run("rsync -a -W #{@repo}/packages/#{@arch}/ #{binpkgs}")
  end

  def repo_tarball(name, ext = 'zst')
    File.join(@repo, 'release', @arch, "#{name}-#{@arch}-latest.tar.#{ext}")
  end

  def unpack_tarball
    tarball, compr = [
      [repo_tarball('stage3'), 'zstd -d -T0'],
      [repo_tarball('stage3', 'xz'), 'xz -d'],
      [repo_tarball('stage3', 'bz2'), 'bzip2 -d']
    ].detect { |e| File.exist?(e[0]) }

    raise "no stage3 tarball found" if tarball.nil?

    # unpack tarball
    FileUtils.mkdir_p @gentoo
    run("cat #{tarball} | #{compr} | tar -C #{@gentoo} -xp")

    # make sure we have working resolv.conf
    FileUtils.cp('/etc/resolv.conf', File.join(@gentoo, '/etc/resolv.conf'))

    # make sure distfiles folder exist
    FileUtils.mkdir_p(File.join(@gentoo, '/var/cache/distfiles'))

    # copy qemu-user in case qemu-build
    qemu = @cfg['qemu']
    unless qemu.nil?
      qemu = "/usr/bin/#{qemu}"
      raise "qemu user not found: #{qemu}" unless File.exist?(qemu)
      FileUtils.cp(qemu, "#{@gentoo}#{qemu}")
    end
  end

  def configure(for_build)
    cfg = @cfg
    cfg = cfg.merge('build' => true) if for_build
    write_template(conf_path('system'), @gentoo, cfg)
  end

  def mounted
    mount
    begin
      yield
    ensure
      umount
    end
  end

  def mount
    run [
      "mount -t proc none #{@gentoo}/proc",
      "mount --rbind /dev #{@gentoo}/dev",
      "mount --rbind /sys #{@gentoo}/sys"
    ]
  end

  def umount
    system("umount -qlR #{@gentoo}/{sys,proc,dev}")
  end

  def cleanup
    umount
    FileUtils.rm_rf @gentoo
  end

  def chrun(cmds, dir = '/')
    cmds = [cmds].flatten
    do_chroot(dir) do
      run(cmds)
    end
  end

  def conf_path(*args)
    File.join(CONF_DIR, args)
  end

  def do_chroot(dir = '/')
    do_forked do
      Dir.chroot(@gentoo)
      Dir.chdir(dir)
      yield
    end
  end

  def do_forked
    read, write = IO.pipe
    pid = fork do
      read.close
      result = yield
      Marshal.dump(result, write)
      exit!(0) # skips exit handlers.
    end

    write.close
    result = read.read
    Process.wait(pid)
    raise "child failed" if result.empty?
    Marshal.load(result)
  end
end

#--------------------------

class ErbContext
  def initialize(props)
    @props = props
  end

  def gen(fn, h = {})
    e = ""
    File.open(fn) do |f|
      e = ERB.new(f.read, nil, "-")
    end
    ec = ErbContext.new(@props.merge(h))
    e.result(ec.get_binding)
  end

  def write(in_file, out_file)
    File.write(out_file, self.gen(in_file))
  end

  def method_missing(method, *opts)
    @props[method.to_s]
  end

  def is_set?(variable)
    @props.has_key?(variable)
  end

  def get(variable, default)
    @props.has_key?(variable) ? @props[variable] : default
  end

  def format(variable, template, default = '')
    return default unless is_set?(variable)
    return template % [ get(variable, '') ]
  end

  def get_binding
    binding
  end
end

#--------------------------

def is_kernel?(args)
  is_kernel = args.shift
  raise 'kernel arg error' unless [nil, 't', 'true', 'kernel'].include?(is_kernel)
  return !is_kernel.nil?
end

#--------------------------

config_dir = File.join(__dir__, 'config')
build_dir = '../build-tmp'
arch = nil
apply = false
phases = [:init, :stage3, :kernel, :stage4, :binpkgs]

args = ARGV.clone

opts = OptionParser.new do |opts|
  opts.banner = 'Usage: build.rb [options] sync|build|apply|delpkg|configure|shell'

  opts.on('-c', '--config DIR', 'Config dir') { |c| config_dir = c }

  opts.on('-a', '--arch ARCH', 'List of arches to build or all') { |a| arch = a }

  opts.on('-A', '--apply', 'Apply changes after building all archs') { |a| apply = a }

  PHASES_HELP = "Build only theese phases." +
      " PHASES: init, stage3 (stage3_build, stage3_pack), kernel (kernel_init, kernel_build)," +
      " stage4 (stage4_build, stage4_pack), binpkgs"

  opts.on('-p', '--phases PHASES', PHASES_HELP) do
    |p| phases = p.split(',').map { |ph| ph.to_sym }
  end

  opts.on('-h', '--help', 'Print this help') do
    puts opts
    exit(1)
  end
end

args = opts.parse(args)

if args.size == 0
  puts opts
  exit(1)
end

BUILD_DIR = build_dir
CONF_DIR = config_dir
CORES = Etc.nprocessors

action = args.shift

sync_repos = ""
if action == 'sync'
  sync_repos = args.join(' ')
  args = []
end

cfg = YAML.load(File.new(File.join(CONF_DIR, 'config.yml')))

if File.exist?('config.user.yml')
  cfg.merge!(YAML.load(File.new('config.user.yml')))
end

def check_args(args)
  raise 'err in args' unless args.empty?
end

def parse_archs(arch, cfg)
  raise 'no arch provided' if arch.nil?
  groups = cfg['groups']
  return groups[arch] if !groups.nil? && groups.has_key?(arch)
  return cfg['archs'].keys if arch == 'all'
  arch.split(',')
end

case action
when 'sync'
  check_args(args)
  sync_repo(cfg['repository'], sync_repos)

when 'build'
  check_args(args)
  parse_archs(arch, cfg).each do |a|
    puts "Building #{a}"
    Builder.new(a, cfg).build(phases)
  end

  if apply
    parse_archs(arch, cfg).each do |a|
      Builder.new(a, cfg).apply
    end
  end

when 'apply'
  check_args(args)
  parse_archs(arch, cfg).each do |a|
    Builder.new(a, cfg).apply
  end

when 'delpkg'
  name = args.shift
  raise 'error in args' if name.nil? || name.empty?
  check_args(args)
  parse_archs(arch, cfg).each do |a|
    Builder.new(a, cfg).drop_package(name)
  end

when 'exec'
  raise 'error in args' if args.empty?
  parse_archs(arch, cfg).each do |a|
    Builder.new(a, cfg).exec(args.join(' '))
  end

when 'configure'
  raise 'error in args' unless args.empty?
  parse_archs(arch, cfg).each do |a|
    Builder.new(a, cfg).configure(true)
  end

when 'shell'
  is_kernel = is_kernel?(args)
  raise 'error in args' unless args.empty?
  archs = parse_archs(arch, cfg)
  raise 'only one arch allowed' unless archs.size == 1
  Builder.new(archs[0], cfg).shell(is_kernel)

else
  raise "unknown action: #{action}"
end
