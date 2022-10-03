# frozen_string_literal: true

require 'English'
require 'pathname'
require 'fileutils'

def env_has_key(key)
  !ENV[key].nil? && ENV[key] != '' ? ENV[key] : abort("Missing #{key}.")
end

def run_command(cmd)
  puts "@@[command] #{cmd}"
  output = `#{cmd}`
  raise 'Command failed' unless $CHILD_STATUS.success?

  output
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

bundle_tool_url = "https://github.com/google/bundletool/releases/download/#{version}/bundletool-all-#{version}.jar"
run_command("curl -L #{bundle_tool_url} -o #{bundle_tool_path}/bundletool.jar")
aab_output_path = "#{ac_temp}/output/bundle"
aab_output = "#{aab_output_path}/#{apk_name}.apks"
apk_output_path = "#{ac_temp}/output/apk"
signed_apk_path = "#{export_path}/#{apk_name}.apk"

cmd = "java -jar #{bundle_tool_path}/bundletool.jar build-apks --overwrite --bundle=#{aab_path} --output=#{aab_output} --mode=universal --ks=\"#{keystore}\" --ks-pass=pass:#{keystore_password} --ks-key-alias=#{keystore_alias} --key-pass=pass:#{keystore_alias_password}"

run_command(cmd)
run_command("unzip -o #{aab_output} -d #{apk_output_path}")
run_command("mv #{apk_output_path}/universal.apk #{signed_apk_path}")

File.open(ENV['AC_ENV_FILE_PATH'], 'a') do |f|
  f.puts "AC_SIGNED_APK_PATH=#{signed_apk_path}"
end

exit 0
