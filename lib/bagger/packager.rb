# encoding: UTF-8
require 'json'
require 'digest/md5'
require 'addressable/uri'
require 'uglifier'
require 'rainpress'

module Bagger
  class Packager

    def initialize(options)
      @options = options
      @stylesheets = (@options[:combine] || {})[:stylesheets] || []
      @javascripts = (@options[:combine] || {})[:javascripts] || []
      @source_dir = @options[:source_dir]
      @target_dir = @options[:target_dir]
      @manifest_path = @options[:manifest_path] || File.join(@source_dir, 'manifest.json')
      @cache_manifest_path = @options[:cache_manifest_path] || 'cache.manifest'
      @stylesheet_path = (@options[:combine] || {})[:stylesheet_path] || 'combined.css'
      @javascript_path = (@options[:combine] || {})[:javascript_path] || 'combined.js'
      @path_prefix = @options[:path_prefix] || ''
      @manifest = {}
    end

    def to_manifest(path, keep_original = true)
      content = File.open(File.join(@target_dir, path)) { |f| f.read }
      extension = File.extname(path)
      basename = File.basename(path, extension)
      dirname = File.dirname(path)
      FileUtils.mkdir_p(File.join(@target_dir, dirname))
      md5 = Digest::MD5.hexdigest(content)
      new_file_name = "#{basename}.#{md5}#{extension}"
      new_file_path = File.join(@target_dir, dirname, new_file_name)
      File.open(new_file_path, 'w') { |f| f.write content }
      FileUtils.rm(File.join(@target_dir, path)) unless keep_original
      manifest_key_path = File.expand_path("/#{dirname}/#{basename}#{extension}")
      effective_path = File.expand_path(@path_prefix + "/" + File.join(dirname, new_file_name))
      @manifest[manifest_key_path] = effective_path
    end

    def run
      combine_css
      combine_js
      version_files
      rewrite_urls_in_css
      compress_css
      to_manifest(@stylesheet_path, false)
      compress_js
      to_manifest(@javascript_path, false)
      generate_and_version_cache_manifest
      write_manifest
    end

    def write_manifest
      File.open(@manifest_path, 'w') do |f|
        f.write JSON.pretty_generate(@manifest)
      end
    end

    def version_files
      FileUtils.cd(@source_dir) do
        Dir["**/*"].reject{ |f| f =~ /\.(css|js)$/ }.each do |path|
          if File.directory? path
            FileUtils.mkdir_p(File.join(@target_dir, path))
            next
          end
          FileUtils.cp(path, File.join(@target_dir, path))
          to_manifest(path, false)
        end
      end
    end

    def combine_css
      combine_files(@stylesheets, @stylesheet_path)
    end

    def rewrite_urls_in_css
      url_regex = /(^|[{;])(.*?url\(\s*['"]?)(.*?)(['"]?\s*\).*?)([;}]|$)/ui
      behavior_regex = /behavior:\s*url/ui
      data_regex = /^\s*data:/ui
      input = File.open(File.join(@target_dir, @stylesheet_path)){|f| f.read}
      output = input.gsub(url_regex) do |full_match|
        pre, url_match, post = ($1 + $2), $3, ($4 + $5)
        if behavior_regex.match(pre) || data_regex.match(url_match)
          full_match
        else
          path = Addressable::URI.parse("/") + url_match
          target_url = @manifest[path.to_s]
          if target_url
            pre + target_url + post
          else
            full_match
          end
        end
      end
      File.open(File.join(@target_dir, @stylesheet_path), 'w') do |f|
        f.write output
      end
    end

    def compress_css
      css = File.open(File.join(@target_dir, @stylesheet_path)){|f| f.read}
      compressed = Rainpress.compress(css)
      File.open(File.join(@target_dir, @stylesheet_path), 'w') do |f|
        f.write compressed
      end
    end

    def combine_js
      combine_files(@javascripts, @javascript_path)
    end

    def compress_js
      javascript = File.open(File.join(@target_dir, @javascript_path)){|f| f.read}
      compressed = Uglifier.compile(javascript)
      File.open(File.join(@target_dir, @javascript_path), 'w'){|f| f.write compressed}
    end

    def generate_and_version_cache_manifest
      path = File.join(@target_dir, @cache_manifest_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'w') do |f|
        f.puts 'CACHE MANIFEST'
        f.puts ''
        f.puts '# Explicitely cached entries'
        f.puts @manifest.values.join("\n")
        f.puts ''
        f.puts 'NETWORK:'
        f.puts '*'
      end
      to_manifest(@cache_manifest_path)
    end

    private

    def combine_files(files, path)
      output = ''
      FileUtils.mkdir_p(File.join(@target_dir, File.dirname(path)))
      target_path = File.join(@target_dir, path)
      files.each do |file|
        output << File.open(File.join(@source_dir, file)) { |f| f.read }
        output << "\n"
      end
      File.open(target_path, "w") { |f| f.write(output) }
    end
  end
end
