#!/usr/bin/env ruby
# frozen_string_literal: true

# Increment mcptask_runner version by 0.1
# Called automatically by the post-merge git hook (bin/hooks/post-merge).
# Do NOT run manually — the hook already calls this after every merge that touches lib/.
# Usage: ruby bin/increment_version.rb

# Add lib to load path
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'mcptask_runner/version'
require 'mcptask_runner/version_manager'

puts "[increment_version] Starting version increment..."
McptaskRunner::VersionManager.increment_version!
puts "[increment_version] Done!"
