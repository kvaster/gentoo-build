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
end

include Helpers

#--------------------------

def sync_repo(repo)
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

  run("PORTAGE_CONFIGROOT=#{tmp} emerge --sync")

  Dir.children(repo).each do |name|
    o = File.join(repo, name)
    puts "checkin #{o}"
    if File.exist?(File.join(o, '.git')) || File.exist?(File.join(o, '.hg'))
      puts "touching #{o}"
      run("touch #{File.join(o, 'metadata', 'timestamp.chk')}")
    end
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

  def build
    puts "Preparing - cleanup"
    cleanup

    puts "Unpacking stage3 tarball"
    unpack_tarball

    puts "Configuring"
    configure(true)

    puts "Copying binary packages"
    copy_binpkgs

    check_profile

    puts "Building stage3"
    build_stage3

    puts "Creating stage3 tarball"
    create_stage3

    puts "Building stage4"
    build_world(@cfg[@cfg['pkgs_stage4']], false)

    puts "Building kernel for stage4"
    build_kernel

    puts "Creating stage4 tarball"
    create_stage4

    puts "Building other binary packages"
    build_world(@cfg[@cfg['pkgs_all']], true)

    puts "Finished"
  end

  def build_kernel
    configure(false)

    FileUtils.cp(conf_path('kernel/genkernel.conf'), File.join(@gentoo, 'etc/genkernel.conf'))

    mount
    begin
      chrun('emerge -q1u sys-kernel/gentoo-sources')

      kernel = "kernel-#{@cfg['os_arch']}-#{@cfg['kernel']}.config"
      FileUtils.cp(conf_path('kernel', kernel), File.join(@gentoo, 'usr/src/linux/.config'))

      kernel_config = @cfg['kernel_config']
      unless kernel_config.nil?
        chrun [
          'scripts/config -d CONFIG_MNATIVE',
          "scripts/config -e CONFIG_#{kernel_config}"
        ], '/usr/src/linux'
      end

      genkernel = @cfg[genkernel]
      if genkernel
        version = do_forked do
          Dir.chroot(@gentoo)
          Dir.chdir('/')
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
        'make install',
        genkernel ? 'genkernel initramfs' : []
      ], '/usr/src/linux'
    ensure
      umount
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
        'emerge -qDuN @world --with-bdeps=y --changed-deps=y --complete-graph=y',
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
      chrun [
        'env-update',
        'emerge -q --sync',
        'env-update',
        'emerge -q1u portage',
        'emerge -q1u gcc binutils glibc',
        'emerge -q --prune gcc binutils glibc',
        'env-update',
        'emerge -qe @system --keep-going --with-bdeps=y',
        'emerge -q --depclean',
        'etc-update --automode -5',
        'eselect news read'
      ]
    end
  end

  def check_profile
    pp = File.join(@gentoo, 'etc/portage/make.profile')
    pl = File.readlink(pp)

    m = /(.*)\/profiles\/(.*)/.match(pl)
    profile = m[2]

    raise "profile is not supported: #{profile}, probably need migration" unless profile == @cfg['profile']

    base = '../../var/db/repos/gentoo'

    unless m[1] == base
      puts "Fixing profile path from #{m[1]} to #{base}"
      FileUtils.ln_s("#{base}/profiles/#{profile}", pp, force: true)
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

  def write_template(template, dst, cfg)
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
    system("umount -qR #{@gentoo}/{sys,proc,dev}")
  end

  def cleanup
    umount
    FileUtils.rm_rf @gentoo
  end

  def chrun(cmds, dir = '/')
    cmds = [cmds].flatten
    do_forked do
      Dir.chroot(@gentoo)
      Dir.chdir(dir)
      run(cmds)
    end
  end

  def conf_path(*args)
    File.join(CONF_DIR, args)
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

config_dir = File.join(__dir__, 'config')
build_dir = 'tmp'
arch = nil
apply = false

args = ARGV.clone

opts = OptionParser.new do |opts|
  opts.banner = 'Usage: build.rb [options] sync|build|apply|delpkg'

  opts.on('-c', '--config DIR', 'Config dir') { |c| config_dir = c }

  opts.on('-a', '--arch ARCH', 'List of arches to build or all') { |a| arch = a }

  opts.on('-A', '--apply', 'Apply changes after building all archs') { |a| apply = a }

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
  sync_repo(cfg['repository'])

when 'build'
  check_args(args)
  parse_archs(arch, cfg).each do |a|
    puts "Building #{a}"
    Builder.new(a, cfg).build
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

else
  raise "unknown action: #{action}"
end
