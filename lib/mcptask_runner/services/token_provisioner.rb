# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

module McptaskRunner
  # Fetches JWTs for configured services and writes them as shell export files
  # into ~/.mcptask_env.d/, then ensures ~/.zshrc sources that directory.
  #
  # Credentials are read from ENV (MCPTASK_EMAIL / MCPTASK_PASSWORD etc.) or
  # prompted interactively when stdin is a TTY. A service is skipped silently
  # when no credentials are available.
  class TokenProvisioner
    Error = Class.new(StandardError)

    ENV_DIR    = File.expand_path('~/.mcptask_env.d').freeze
    ZSHRC_PATH = File.expand_path('~/.zshrc').freeze

    TOKEN_SERVICES = [
      {
        env_var:   'MCPTASK_TOKEN',
        filename:  'mcptask_token',
        url:       'https://mcptask.online/api/sessions',
        email_env: 'MCPTASK_EMAIL',
        pass_env:  'MCPTASK_PASSWORD',
        label:     'mcptask.online'
      },
      {
        env_var:   'WORKVECTOR_KAMR_TOKEN',
        filename:  'workvector_kamr_token',
        url:       'https://mcptask.online/api/sessions',
        email_env: 'MCPTASK_KAMR_EMAIL',
        pass_env:  'MCPTASK_KAMR_PASSWORD',
        label:     'mcptask.online (KAMR)'
      },
      {
        env_var:   'LLMMN_TOKEN',
        filename:  'llmmn_token',
        url:       'https://llm-memory.com/api/sessions',
        email_env: 'LLMMN_EMAIL',
        pass_env:  'LLMMN_PASSWORD',
        label:     'llm-memory.com'
      }
    ].freeze

    OBSOLETE_SCRIPTS = %w[
      get_workvector_token.sh
      get_workvector_kamr_token.sh
      get_llmmn_token.sh
    ].freeze

    def initialize(env_dir: ENV_DIR, zshrc: ZSHRC_PATH, services: TOKEN_SERVICES, home: File.expand_path('~'))
      @env_dir  = env_dir
      @zshrc    = zshrc
      @services = services
      @home     = home
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def call
      configure_zshrc
      provision_all_tokens
      remove_obsolete_scripts
    end

    private

    def configure_zshrc
      unless File.exist?(@zshrc)
        puts "[TokenProvisioner] ~/.zshrc not found — skipping sourcing setup"
        return
      end

      if File.read(@zshrc).include?(@env_dir)
        puts "[TokenProvisioner] ~/.zshrc already sources #{@env_dir} — no change needed"
        return
      end

      FileUtils.mkdir_p(@env_dir)
      File.open(@zshrc, 'a') { |f| f.write(zshrc_snippet) }
      puts "[TokenProvisioner] ~/.zshrc updated: will source #{@env_dir}/*"
    end

    def zshrc_snippet
      <<~SHELL

        # mcptask_runner tokens
        for file in #{@env_dir}/*; do
          [ -f "$file" ] && source "$file"
        done
      SHELL
    end

    def provision_all_tokens
      FileUtils.mkdir_p(@env_dir)
      @services.each { |s| provision_token(s) }
    end

    def provision_token(service)
      email, password = credentials_for(service)

      if email.empty? || password.empty?
        puts "[TokenProvisioner] Skipping #{service[:env_var]} — no credentials provided"
        return
      end

      token = fetch_token(service[:url], email, password)
      write_env_file(service[:env_var], service[:filename], token)
      puts "[TokenProvisioner] #{service[:env_var]} written to #{@env_dir}/#{service[:filename]}"
    rescue Error => e
      warn "[TokenProvisioner] WARNING: #{service[:env_var]} fetch failed: #{e.message}"
    end

    def credentials_for(service)
      email    = ENV.fetch(service[:email_env], '').strip
      password = ENV.fetch(service[:pass_env], '').strip

      if (email.empty? || password.empty?) && $stdin.isatty
        puts "[TokenProvisioner] Credentials for #{service[:label]} (#{service[:env_var]}):"
        $stdout.print '  Email (blank to skip): '
        $stdout.flush
        email = $stdin.gets&.chomp.to_s.strip

        unless email.empty?
          $stdout.print '  Password: '
          $stdout.flush
          password = $stdin.gets&.chomp.to_s.strip
        end
      end

      [email, password]
    end

    def fetch_token(url, email, password)
      uri  = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == 'https')
      http.open_timeout = 10
      http.read_timeout = 10

      req      = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
      req.body = JSON.generate(session: { email: email, password: password })

      resp  = http.request(req)
      token = JSON.parse(resp.body)['token'].to_s
      raise Error, "empty token (HTTP #{resp.code}): #{resp.body[0..200]}" if token.empty? || token == 'null'

      token
    end

    def write_env_file(env_var, filename, token)
      path = File.join(@env_dir, filename)
      File.write(path, "export #{env_var}=\"#{token}\"\n")
      FileUtils.chmod(0o600, path)
    end

    def remove_obsolete_scripts
      OBSOLETE_SCRIPTS.each do |script|
        path = File.join(@home, script)
        next unless File.exist?(path)

        FileUtils.rm(path)
        puts "[TokenProvisioner] Removed obsolete script: #{path}"
      end
    end
  end
end
