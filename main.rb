# frozen_string_literal: true

require 'English'
require 'pathname'
require 'fileutils'
require 'digest'

DEFAULT_BUNDLETOOL_BASE_URL = 'https://github.com'

def get_env_variable(key)
  ENV[key].nil? || ENV[key].strip.empty? ? nil : ENV[key].strip
end

def env_has_key(key)
  get_env_variable(key) || abort("Missing #{key}.")
end

def run_command(cmd)
  puts "@@[command] #{cmd}"
  output = `#{cmd}`
  raise 'Command failed' unless $CHILD_STATUS.success?

  output
end

# Priority: AC_BUNDLETOOL_URL (used as is), then AC_BUNDLETOOL_BASE_URL, then GitHub.
def bundletool_download_url(version)
  full_url = get_env_variable('AC_BUNDLETOOL_URL')
  return full_url if full_url

  base_url = (get_env_variable('AC_BUNDLETOOL_BASE_URL') || DEFAULT_BUNDLETOOL_BASE_URL).chomp('/')
  "#{base_url}/google/bundletool/releases/download/#{version}/bundletool-all-#{version}.jar"
end

def mask_url(url)
  url.sub(%r{//[^/@]+@}, '//***@')
end

def verify_bundletool(path, url)
  unless File.binread(path, 4) == "PK\x03\x04".b
    FileUtils.rm_f(path)
    abort("@@[error] The file downloaded from #{mask_url(url)} is not a valid jar.")
  end

  expected = get_env_variable('AC_BUNDLETOOL_SHA256')
  return unless expected

  actual = Digest::SHA256.file(path).hexdigest
  if actual.casecmp?(expected)
    puts 'Bundletool SHA-256 checksum verified.'
    return
  end

  FileUtils.rm_f(path)
  abort("@@[error] Bundletool SHA-256 mismatch. Expected #{expected}, got #{actual}.")
end

# The jar is cached by the file name in the URL, so a different version is downloaded again.
def download_bundletool(url, target_dir)
  file_name = File.basename(url.split('?').first)
  file_name = "#{file_name}.jar" unless file_name.end_with?('.jar')
  jar_path = File.join(target_dir, file_name)
  if File.exist?(jar_path)
    puts "Bundletool is already downloaded: #{jar_path}"
    return jar_path
  end

  puts "Downloading bundletool from #{mask_url(url)}"
  tmp_path = "#{jar_path}.download"
  unless system('curl', '-fsSL', '--retry', '3', '-o', tmp_path, url)
    FileUtils.rm_f(tmp_path)
    abort("@@[error] Failed to download bundletool from #{mask_url(url)}. " \
          'Check AC_BUNDLETOOL_VERSION, AC_BUNDLETOOL_URL and AC_BUNDLETOOL_BASE_URL.')
  end
  verify_bundletool(tmp_path, url)
  FileUtils.mv(tmp_path, jar_path)
  jar_path
end

version = env_has_key('AC_BUNDLETOOL_VERSION')
ac_temp = env_has_key('AC_TEMP_DIR')
aab_path = env_has_key('AC_SIGNED_AAB_PATH')
keystore = env_has_key('AC_ANDROID_KEYSTORE_PATH')
keystore_password = env_has_key('AC_ANDROID_KEYSTORE_PASSWORD')
keystore_alias = env_has_key('AC_ANDROID_ALIAS')
keystore_alias_password = env_has_key('AC_ANDROID_ALIAS_PASSWORD')
export_path = env_has_key('AC_OUTPUT_DIR')
apk_name = File.basename(aab_path, '.aab')
bundle_tool_path = File.join(ac_temp, 'bundletool')

FileUtils.mkdir_p(bundle_tool_path) unless File.directory?(bundle_tool_path)

puts 'AC_BUNDLETOOL_URL is set, AC_BUNDLETOOL_VERSION is not used for the download.' if get_env_variable('AC_BUNDLETOOL_URL')
bundle_tool_jar = download_bundletool(bundletool_download_url(version), bundle_tool_path)
aab_output_path = "#{ac_temp}/output/bundle"
aab_output = "#{aab_output_path}/#{apk_name}.apks"
apk_output_path = "#{ac_temp}/output/apk"
signed_apk_path = "#{export_path}/#{apk_name}.apk"

cmd = "java -jar \"#{bundle_tool_jar}\" build-apks --overwrite --bundle=#{aab_path} --output=#{aab_output} --mode=universal --ks=\"#{keystore}\" --ks-pass=pass:#{keystore_password} --ks-key-alias=#{keystore_alias} --key-pass=pass:#{keystore_alias_password}"

run_command(cmd)
run_command("unzip -o #{aab_output} -d #{apk_output_path}")
run_command("mv #{apk_output_path}/universal.apk #{signed_apk_path}")

File.open(ENV['AC_ENV_FILE_PATH'], 'a') do |f|
  f.puts "AC_SIGNED_APK_PATH=#{signed_apk_path}"
end

exit 0
