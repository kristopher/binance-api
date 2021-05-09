require 'bundler'
require 'pathname'
require 'yaml'
require 'json'
require 'erb'

Bundler.require

require 'dotenv'
require 'active_support/all'

Dotenv.load

APP_ROOT = Pathname.new(File.expand_path(File.dirname(__FILE__)))

Config = YAML.load(ERB.new(File.read(APP_ROOT + 'config' + 'config.yml')).result(binding)).with_indifferent_access

require_relative 'lib/binance'

Binance.config = {
  api_key: Config[:binance][:api_key],
  secret_key: Config[:binance][:secret_key],
}