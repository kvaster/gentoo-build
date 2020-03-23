#!/usr/bin/ruby

require 'set'

def parse_flags(args)
  flags = {}
  `LC_ALL=en_US.utf8 gcc -Q --help=target #{args}`.split("\n").each do |line|
    m = /-m([^\s]*)\s+\[((?:enabled)|(?:disabled))\]/.match(line)
    flags[m[1]] = m[2] == 'enabled' if m
  end
  
  flags
end

def arg_size(arg)
  sz = arg.size
  sz = 6 if sz < 6
  sz
end

keys = Set.new
flags = []

ARGV.each do |arg|
  f = parse_flags(arg)
  flags << f
  keys += f.keys
end

f1 = parse_flags(ARGV[0])
f2 = parse_flags(ARGV[1])

argv = ARGV.map { |a| "'#{a}'" }
argv.each_index { |i| flags[i][:size] = arg_size(argv[i]) }

puts ("%40s " % "archs: ") + argv.map { |a| "%#{arg_size(a)}s" % a }.join(' ')

keys.each do |k|
  v = flags[0][k]
  unless flags.index { |f| f[k] != v }.nil?
    puts ("%40s " % "-m#{k}") + flags.map { |f| "%#{f[:size]}s" % f[k] }.join(' ')
  end
end

#diff = []
#
#f1.each do |k,v|
#  if v != f2[k]
#    diff << k
#  end
#end
#
#f2.each do |k,v|
#  if v != f1[k]
#    diff << k
#  end
#end
#
#diff.uniq!
#
#puts "DIFF: '#{ARGV[0]}' vs '#{ARGV[1]}'"
#
#diff.each do |k|
#  puts "-m#{k} #{f1[k]} #{f2[k]}"
#end
