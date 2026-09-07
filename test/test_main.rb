# frozen_string_literal: true

unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  GROUP_COLORS = [
    "\e[34;1m",
    "\e[35;1m",
    "\e[36;1m",
    "\e[33;1m"
  ].freeze

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

REQUIRED_ENV_KEYS = %w[
  AC_BUNDLETOOL_VERSION
  AC_TEMP_DIR
  AC_SIGNED_AAB_PATH
  AC_ANDROID_KEYSTORE_PATH
  AC_ANDROID_KEYSTORE_PASSWORD
  AC_ANDROID_ALIAS
  AC_ANDROID_ALIAS_PASSWORD
  AC_OUTPUT_DIR
  AC_ENV_FILE_PATH
].freeze

def full_env(tmpdir)
  {
    'AC_BUNDLETOOL_VERSION'        => '1.15.6',
    'AC_TEMP_DIR'                  => tmpdir,
    'AC_SIGNED_AAB_PATH'           => File.join(tmpdir, 'app-release.aab'),
    'AC_ANDROID_KEYSTORE_PATH'     => File.join(tmpdir, 'release.keystore'),
    'AC_ANDROID_KEYSTORE_PASSWORD' => 'ks_pass',
    'AC_ANDROID_ALIAS'             => 'release',
    'AC_ANDROID_ALIAS_PASSWORD'    => 'alias_pass',
    'AC_OUTPUT_DIR'                => File.join(tmpdir, 'out'),
    'AC_ENV_FILE_PATH'             => File.join(tmpdir, 'env.txt')
  }
end

def run_main(env = {})
  clean_env = REQUIRED_ENV_KEYS.to_h { |k| [k, nil] }.merge(env)
  Open3.capture3(clean_env, "ruby #{MAIN_RB}")
end

RSpec.describe '#env_has_key' do
  around do |example|
    saved = ENV['_AC_TEST_KEY']
    example.run
    ENV['_AC_TEST_KEY'] = saved
  end

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_AC_TEST_KEY'] = 'my_value'
      expect(env_has_key('_AC_TEST_KEY')).to eq('my_value')
    end

    it 'returns a path-like value without modification' do
      ENV['_AC_TEST_KEY'] = '/tmp/some/path'
      expect(env_has_key('_AC_TEST_KEY')).to eq('/tmp/some/path')
    end
  end

  context 'negative path' do
    before { allow($stderr).to receive(:write) }

    it 'raises SystemExit when the key is not set' do
      ENV.delete('_AC_TEST_KEY')
      expect { env_has_key('_AC_TEST_KEY') }.to raise_error(SystemExit)
    end

    it 'raises SystemExit when the value is an empty string' do
      ENV['_AC_TEST_KEY'] = ''
      expect { env_has_key('_AC_TEST_KEY') }.to raise_error(SystemExit)
    end

    it 'exits with status 1 and a message naming the key' do
      ENV.delete('_AC_TEST_KEY')
      expect { env_has_key('_AC_TEST_KEY') }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
        expect(e.message).to eq('Missing _AC_TEST_KEY.')
      }
    end
  end
end

RSpec.describe '#run_command' do
  before { allow($stdout).to receive(:puts) }

  context 'positive path' do
    it 'returns the command output on success' do
      expect(run_command('echo hi')).to eq("hi\n")
    end

    it 'prints the command with the @@[command] prefix' do
      expect($stdout).to receive(:puts).with('@@[command] echo hi')
      run_command('echo hi')
    end

    it 'passes the composed command string to the shell unchanged' do
      captured = nil
      allow(self).to receive(:`) do |cmd|
        captured = cmd
        system('true')
        'stubbed'
      end
      expect(run_command('java -jar bundletool.jar build-apks')).to eq('stubbed')
      expect(captured).to eq('java -jar bundletool.jar build-apks')
    end
  end

  context 'negative path' do
    it 'raises RuntimeError when the command exits non-zero' do
      expect { run_command('sh -c "exit 1"') }.to raise_error(RuntimeError, 'Command failed')
    end

    it 'raises Errno::ENOENT for an empty command' do
      expect { run_command('') }.to raise_error(Errno::ENOENT)
    end

    it 'raises Errno::ENOENT for a nil command' do
      expect { run_command(nil) }.to raise_error(Errno::ENOENT)
    end
  end
end

RSpec.describe 'ENV validation' do
  let(:tmpdir) { Dir.mktmpdir('bundletool_env_test') }
  after { FileUtils.rm_rf(tmpdir) }

  shared_examples 'a failing validation' do |key|
    it 'fails when the variable is missing' do
      _out, err, status = run_main(full_env(tmpdir).merge(key => nil))
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Missing #{key}.")
    end

    it 'fails when the variable is an empty string' do
      _out, err, status = run_main(full_env(tmpdir).merge(key => ''))
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Missing #{key}.")
    end
  end

  REQUIRED_ENV_KEYS.each do |key|
    context key do
      include_examples 'a failing validation', key
    end
  end

  it 'does not touch the filesystem when validation fails' do
    run_main(full_env(tmpdir).merge('AC_ENV_FILE_PATH' => nil))
    expect(Dir.exist?(File.join(tmpdir, 'bundletool'))).to be(false)
    expect(File.exist?(File.join(tmpdir, 'env.txt'))).to be(false)
  end
end

def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = result[main_path]
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
