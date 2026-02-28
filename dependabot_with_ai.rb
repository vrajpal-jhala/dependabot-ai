#!/usr/bin/env ruby

require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/metadata_finders"
require "dependabot/omnibus"
require "json"
require "net/http"
require "uri"
require "shellwords"
require "timeout"

class DependabotWithAI
  def initialize
    @start_time = Time.now
    @step_timings = {}

    # Changelog configuration
    @changelog_token_limit = 800
    @rate_limited_packages = []

    # Enable Dependabot's internal debug logging
    ENV['DEBUG'] = 'true'
    ENV['DEPENDABOT_DEBUG'] = 'true'
    ENV['NPM_CONFIG_LOGLEVEL'] = 'verbose'

    # Enable Ruby logger for more internal details
    require 'logger'
    Dependabot.logger = Logger.new(STDOUT)
    Dependabot.logger.level = Logger::DEBUG if defined?(Dependabot.logger)

    step_start = Time.now
    @config = load_config
    @target_branch = @config.dig("settings", "target_branch") || ENV["TARGET_BRANCH"]
    @gitlab_host = "https://gitlab.com"
    @project_path = ENV["CI_PROJECT_PATH"]
    @npm_registry = ENV["NPM_REGISTRY"]
    # Normalize registry URL to avoid double https:// issues
    if @npm_registry
      # More robust normalization - handle various URL formats
      @npm_registry = @npm_registry.strip
      @npm_registry = @npm_registry.sub(/^https?:\/\//, '')  # Remove any existing protocol
      @npm_registry = @npm_registry.sub(/\/$/, '')           # Remove trailing slash
      @npm_registry = "https://#{@npm_registry}"
      puts "🔧 Normalized NPM registry URL: #{@npm_registry}"             # Add single https://
    end
    @npm_auth_token = ENV["NPM_AUTH_TOKEN"]
    @github_token = ENV["GITHUB_TOKEN"]
    @openrouter_api_key = ENV["OPENROUTER_API_KEY"]
    @pipeline_id = ENV["CI_PIPELINE_ID"]
    @analysis_model = @config.dig("settings", "ai_analysis", "model") || ENV["AI_ANALYSIS_MODEL"]
    @mr_assignee_username = @config.dig("settings", "mr_assignee_username") || ENV["MR_ASSIGNEE_USERNAME"]
    @credentials = setup_credentials

    record_step_time("Initialization", step_start)
  end

  def run
    puts "🚀 Starting Dependabot with AI analysis..."
    puts "🔑 OpenRouter API Key: #{@openrouter_api_key&.length ? "✅ Set" : '❌ Missing'}"
    puts "🤖 AI Analysis: #{@config.dig('settings', 'ai_analysis', 'enabled') ? '✅ Enabled' : '❌ Disabled'}"

    # Show configuration sources
    target_source = @config.dig("settings", "target_branch") ? "config" : "env"
    assignee_source = @config.dig("settings", "mr_assignee_username") ? "config" : "env"

    puts "🎯 Target Branch: #{@target_branch} (from #{target_source})"
    puts "👤 MR Assignee: #{(@mr_assignee_username && !@mr_assignee_username.empty?) ? "#{@mr_assignee_username} (from #{assignee_source})" : 'none'}"

    step_start = Time.now
    dependencies = fetch_and_parse_dependencies
    return if dependencies.empty?
    record_step_time("Fetch & Parse Dependencies", step_start)

    step_start = Time.now
    updates = check_for_updates(dependencies)
    return if updates.empty?
    record_step_time("Check for Updates", step_start)

    step_start = Time.now
    # Process updates first, AI analysis later
    result = create_merge_request(updates)
    record_step_time("Total Update Workflow", step_start)

    print_timing_summary
    result
  end

  def create_merge_request(updates)
    # Process each dependency individually from the start (no AI analysis yet)
    return process_individual_updates(updates)
  end

  def process_individual_updates(updates)
    step_start = Time.now
    puts "🔄 Processing dependencies individually..."
    successful_updates = { deps: [], files: updates[:files], summaries: [] }
    failed_updates = []

    total_count = updates[:deps].length
    puts "📊 Total updates to process: #{total_count}"

    # Start with base files
    current_files = updates[:files]

    updates[:deps].each_with_index do |dep, index|
      current_number = index + 1
      remaining_count = total_count - current_number

      puts "🔍 [#{current_number}/#{total_count}] Updating #{dep.name} (#{dep.version})"

      begin
        # Try updating just this dependency using current state of files
        individual_updater = Dependabot::FileUpdaters.for_package_manager("npm_and_yarn").new(
          dependencies: [dep],
          dependency_files: current_files,
          credentials: get_credentials
        )

        updated_files = individual_updater.updated_dependency_files

        # If successful, add to successful updates and update current files
        successful_updates[:deps] << dep
        successful_updates[:summaries] << updates[:summaries][index] if updates[:summaries][index]

        # Use the updated files for the next dependency update
        current_files = updated_files

        puts "✅ [#{current_number}/#{total_count}] Successfully updated #{dep.name}"

      rescue => e
        puts "❌ [#{current_number}/#{total_count}] Failed to update #{dep.name}: #{e.class}: #{e.message}"

        failed_updates << {
          dep: dep,
          error: e.message,
          error_class: e.class.to_s,
        }
      end
    end

    # Store the final accumulated files
    successful_updates[:files] = current_files
    record_step_time("Process Individual Updates", step_start)

    if successful_updates[:deps].any?
      puts ""
      puts "📊 Update Summary:"
      puts "✅ Successfully updated: #{successful_updates[:deps].length} dependencies"
      puts "❌ Failed to update: #{failed_updates.length} dependencies" if failed_updates.any?

      # Log failed dependencies
      if failed_updates.any?
        puts ""
        puts "❌ Failed updates:"
        failed_updates.each do |failure|
          puts "   - #{failure[:dep].name}: #{failure[:error_class]}: #{failure[:error]}"
        end
      end

      # Write updated files (needed for MR creation and AI analysis)
      puts ""
      puts "📝 Writing updated files..."
      successful_updates[:files].each do |file|
        File.write(file.name, file.content)
        puts "📝 Updated #{file.name}"
      end
      puts "✅ All files updated successfully"

      # NOW do AI analysis on only successful updates
      ai_analysis = nil
      if @openrouter_api_key && @config.dig('settings', 'ai_analysis', 'enabled')
        puts ""
        ai_step_start = Time.now
        ai_analysis = analyze_successful_updates_with_ai(successful_updates)
        record_step_time("AI Analysis", ai_step_start)
      end

      # Create single MR with all successful updates and AI analysis
      mr_step_start = Time.now
      result = create_successful_updates_merge_request(successful_updates, ai_analysis, failed_updates)
      record_step_time("Create MR", mr_step_start)
      return result
    else
      puts "❌ No dependencies could be updated successfully"
      return false
    end
  end

  def create_successful_updates_merge_request(updates, ai_analysis, failed_updates = [])
    puts "🔄 Creating MR with #{updates[:deps].length} successful updates..."

    # Use the already updated files
    updated_files = updates[:files]

    # Create single branch and MR for all successful updates
    timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
    branch_name = "dependabot/update-#{timestamp}"

    puts "🌿 Creating branch #{branch_name}"
    unless system("git checkout -b #{branch_name}")
      puts "❌ Failed to create branch"
      return false
    end

    # Files already written during AI analysis phase

    # Commit and push all changes
    unless system("git add package.json package-lock.json")
      puts "❌ Failed to add files to git"
      return false
    end

    # Create pipeline link for detailed logs when needed
    pipeline_url = "#{@gitlab_host}/#{@project_path}/-/pipelines/#{@pipeline_id}"

    # Create concise commit message
    update_list = updates[:summaries].map do |update|
      "- `#{update[:name]}`: #{update[:old_version]} → #{update[:new_version]} #{update[:strategy]}"
    end.join("\n")

    # Count update types for commit message
    major_count = updates[:summaries].count { |u| u[:strategy] == "(major)" }
    minor_count = updates[:summaries].count { |u| u[:strategy] == "(minor)" }
    patch_count = updates[:summaries].count { |u| u[:strategy] == "(patch)" }
    failed_count = failed_updates.length

    # Build ultra-concise commit message
    commit_parts = []
    commit_parts << "#{major_count} major" if major_count > 0
    commit_parts << "#{minor_count} minor" if minor_count > 0
    commit_parts << "#{patch_count} patch" if patch_count > 0
    commit_parts << "#{failed_count} skipped" if failed_count > 0

    commit_msg = "chore(deps): #{commit_parts.join(', ')}"

    unless system("git", "commit", "-m", commit_msg)
      puts "❌ Failed to commit changes"
      return false
    end
    puts "✅ Committed changes"

    # We'll push the branch with MR creation in one step
    puts "🔄 Will push branch with MR creation..."

    # Create enhanced MR description
    mr_title = "chore(deps): update #{updates[:deps].length} dependencies"

    if failed_updates.any?
      basic_description = "✅ Successfully updated #{updates[:deps].length} dependencies:\n\n#{update_list}\n\n"
      basic_description += "⚠️ #{failed_updates.length} dependencies were skipped due to conflicts:\n"
      failed_updates.each do |failure|
        basic_description += "- `#{failure[:dep].name}`: #{failure[:error]}\n"
      end
      basic_description += "\n**[→ View detailed pipeline logs](#{pipeline_url})** for complete error information and debugging details.\n"
      puts "🔗 Added pipeline link to failed updates section: #{pipeline_url}"
    else
      basic_description = "✅ Updated #{updates[:deps].length} dependencies:\n\n#{update_list}"
    end

    if ai_analysis
      mr_description = """#{basic_description}

## 🤖 AI Analysis

#{ai_analysis}

#{@rate_limited_packages.any? ? "⚠️ **Incomplete AI analysis:** Rate limit hit when fetching changelogs for some dependencies. To get the complete AI analysis, re-run the [pipeline](#{pipeline_url})." : ""}
"""
    else
      mr_description = basic_description
    end

    # Create merge request using existing logic
    mr_result = create_gitlab_mr(branch_name, mr_title, mr_description)

    if mr_result[:success]
      puts "✅ Created MR successfully#{ai_analysis ? " with AI analysis ✨" : ""}"
      puts "🔗 Branch: #{branch_name}"
      puts "🎯 Target: #{@target_branch}"
      puts "📝 Updates: #{updates[:deps].length} dependencies"
      puts "⚠️  Skipped: #{failed_updates.length} dependencies" if failed_updates.any?
      puts "🚫 Rate limited: #{@rate_limited_packages.length || 0} packages" if @rate_limited_packages.any?

      if mr_result[:mr_id]
        puts "🌐 MR !#{mr_result[:mr_id]}: #{mr_result[:url]}"
      else
        puts "🌐 MR URL: #{mr_result[:url]}"
      end
    else
      puts "❌ Failed to create MR"
      return false
    end

    true
  end

  def extract_mr_id_from_output(output)
    # GitLab returns MR creation URLs in various formats:
    # "To create a merge request for branch, visit: https://gitlab.com/project/-/merge_requests/new?merge_request%5Bsource_branch%5D=branch"
    # Or sometimes includes the actual MR URL after creation

    # Look for MR ID in the output
    mr_id_patterns = [
      /merge_requests\/(\d+)/,                    # Direct MR URL: /merge_requests/123
      /!([0-9]+)/,                                # GitLab MR notation: !123
      /merge_request_iid=(\d+)/,                  # API parameter: merge_request_iid=123
    ]

    mr_id_patterns.each do |pattern|
      match = output.match(pattern)
      if match
        puts "✅ Extracted MR ID: #{match[1]}"
        return match[1]
      end
    end

    puts "⚠️  Could not extract MR ID from git output"
    nil
  end

  def create_gitlab_mr(branch_name, mr_title, mr_description)
    # Create MR using git push options (GitLab feature)
    # Prepare description for push options (GitLab push options require single line)
    # Replace newlines with literal \n for GitLab to interpret as line breaks
    escaped_description = mr_description.gsub(/\n/, '\\n').strip

    push_cmd = [
      "git", "push", "-u", "origin", branch_name,
      "-o", "merge_request.create",
      "-o", "merge_request.target=#{@target_branch}",
      "-o", "merge_request.title=#{mr_title}",
      "-o", "merge_request.description=#{escaped_description}"
    ]

    # Optional assignee via push options
    if @mr_assignee_username && !@mr_assignee_username.empty?
      push_cmd += ["-o", "merge_request.assign=#{@mr_assignee_username}"]
    end

    puts "🔄 Pushing branch and creating GitLab MR..."

    # Capture git push output to extract MR URL
    output = `#{push_cmd.map { |arg| Shellwords.escape(arg) }.join(' ')} 2>&1`
    success = $?.success?

    if success
      puts "✅ Pushed branch #{branch_name}"

      # Try to extract MR ID from GitLab's response
      mr_id = extract_mr_id_from_output(output)
      puts "🔍 Git push output: #{output}" if ENV['DEBUG']
      project_url = "#{@gitlab_host}/#{@project_path}"

      if mr_id
        mr_url = "#{project_url}/-/merge_requests/#{mr_id}"
        return {
          success: true,
          url: mr_url,
          mr_id: mr_id,
          branch: branch_name
        }
      else
        # Fallback if we couldn't extract MR ID
        mr_url = "#{project_url}/-/merge_requests"
        return {
          success: true,
          url: "#{mr_url} (check latest MR for branch: #{branch_name})",
          branch: branch_name
        }
      end
    else
      return { success: false, url: nil }
    end
  end

  def get_update_strategy(dep_name, is_dev_dep = false)
    deps_config = @config["dependencies"] || {}

    # Check if dependency should be ignored
    return :ignore if deps_config["ignore"]&.any? { |pattern|
      File.fnmatch(pattern, dep_name, File::FNM_CASEFOLD | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
    }

    # Check specific rules first
    if deps_config["patch_only"]&.any? { |pattern|
      File.fnmatch(pattern, dep_name, File::FNM_CASEFOLD | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
    }
      return :none  # patch only
    end

    if deps_config["major_updates"]&.any? { |pattern|
      File.fnmatch(pattern, dep_name, File::FNM_CASEFOLD | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
    }
      return :all   # major updates allowed
    end

    if deps_config["minor_updates"]&.any? { |pattern|
      File.fnmatch(pattern, dep_name, File::FNM_CASEFOLD | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
    }
      return :own   # minor updates
    end

    # Use dev dependencies strategy if applicable
    if is_dev_dep
      dev_strategy = @config.dig("dev_dependencies", "update_strategy") || "minor_and_patch"
      case dev_strategy
      when "patch_only" then :none
      when "all" then :all
      else :own
      end
    else
      # Use global strategy
      global_strategy = @config.dig("settings", "update_strategy") || "minor_and_patch"
      case global_strategy
      when "patch_only" then :none
      when "all" then :all
      else :own
      end
    end
  end

  def setup_credentials
    credentials = []

    # Add npm registry credential if NPM_AUTH_TOKEN is available
    if @npm_auth_token && @npm_registry
      # Ensure registry URL doesn't have protocol for Dependabot credentials
      registry_for_credentials = @npm_registry.sub(/^https?:\/\//, '')

      credentials << Dependabot::Credential.new({
        "type" => "npm_registry",
        "registry" => registry_for_credentials,
        "token" => @npm_auth_token
      })
      puts "🔐 Added private npm registry credentials for #{@registry_for_credentials}"
    else
      puts "⚠️  Warning: NPM credentials incomplete - private packages may fail"
    end

    # Add GitHub token for authenticated API requests (higher rate limits: 5000/hour vs 60/hour)
    if @github_token
      credentials << Dependabot::Credential.new({
        "type" => "git_source",
        "host" => "github.com",
        "username" => "x-access-token",
        "password" => @github_token
      })
      puts "🔐 Added GitHub token for authenticated API requests (5000/hour rate limit)"
    else
      puts "⚠️  Warning: GITHUB_TOKEN not set - using lower rate limits (60/hour vs 5000/hour)"
    end

    credentials
  end

  def get_credentials
    @credentials
  end

  def check_github_rate_limit_status
    return unless @github_token

    begin
      puts "🔍 Checking GitHub API rate limit status..."

      uri = URI("https://api.github.com/rate_limit")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 10

      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "token #{@github_token}"
      request["User-Agent"] = "Dependabot-CI/1.0"

      response = http.request(request)

      if response.code == "200"
        data = JSON.parse(response.body)
        core_limit = data.dig("resources", "core")

        if core_limit
          used = core_limit["used"]
          limit = core_limit["limit"]
          remaining = core_limit["remaining"]
          reset_time = Time.at(core_limit["reset"])

          puts "📊 GitHub API Rate Limit Status:"
          puts "   Used: #{used}/#{limit} (#{remaining} remaining)"
          puts "   Resets: #{reset_time.strftime('%H:%M:%S UTC')}"

          # Warning if running low
          percentage_used = (used.to_f / limit * 100).round(1)
          if percentage_used > 80
            puts "⚠️  Warning: #{percentage_used}% of rate limit used"
          elsif percentage_used > 95
            puts "🚨 Critical: #{percentage_used}% of rate limit used - consider waiting"
          end
        else
          puts "⚠️  Could not parse rate limit data"
        end
      elsif response.code == "401"
        puts "❌ GitHub token authentication failed - check GITHUB_TOKEN"
      else
        puts "⚠️  GitHub API rate limit check failed (#{response.code}): #{response.body}"
      end

    rescue => e
      puts "⚠️  Error checking GitHub rate limit: #{e.message}"
    end
  end

  def fetch_and_parse_dependencies
    package_manager = "npm_and_yarn"

    # Configure GitLab source for gitlab.com
    source = Dependabot::Source.new(
      provider: "gitlab",
      repo: @project_path
    )

    # Read local dependency files
    files = []
    if File.exist?("package.json")
      files << Dependabot::DependencyFile.new(
        name: "package.json",
        content: File.read("package.json")
      )
      puts "📄 Found package.json"
    else
      puts "❌ package.json not found"
      return []
    end

    if File.exist?("package-lock.json")
      files << Dependabot::DependencyFile.new(
        name: "package-lock.json",
        content: File.read("package-lock.json")
      )
      puts "📄 Found package-lock.json"
    else
      puts "⚠️  package-lock.json not found - some features may be limited"
    end

    puts "🔍 Found #{files.length} dependency files"

    parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
      dependency_files: files,
      source: source
    )

    dependencies = parser.parse
    puts "📦 Found #{dependencies.length} dependencies"

    { dependencies: dependencies, files: files, source: source }
  end

  def check_for_updates(deps_data)
    dependencies = deps_data[:dependencies]
    files = deps_data[:files]

    top_level_deps = dependencies.select(&:top_level?)
    puts "🔍 Checking #{top_level_deps.length} dependencies for updates..."

    all_updated_deps = []
    update_summaries = []

    # Process dependencies
    top_level_deps.each do |dep|
      check_single_dependency_for_update(dep, files, all_updated_deps, update_summaries)
    end

    if all_updated_deps.empty?
      puts "📋 No dependency updates available"
      return []
    end

    puts "🔄 Found #{all_updated_deps.length} dependency updates"

    {
      deps: all_updated_deps.to_a,
      summaries: update_summaries.to_a,
      files: files
    }
  end

  def check_single_dependency_for_update(dep, files, all_updated_deps, update_summaries)
    # Determine if it's a dev dependency
    is_dev_dep = dep.requirements.any? { |req| req[:groups]&.include?("development") }

    # Get update strategy for this dependency
    update_strategy = get_update_strategy(dep.name, is_dev_dep)

    if update_strategy == :ignore
      puts "⏭️  Skipping #{dep.name} (ignored in config)"
      return
    end

    puts "🔍 Checking #{dep.name} (#{dep.version}) - strategy: #{update_strategy}"

    checker = Dependabot::UpdateCheckers.for_package_manager("npm_and_yarn").new(
      dependency: dep,
      dependency_files: files,
      credentials: get_credentials
    )

    return if checker.up_to_date?

    updated_deps = checker.updated_dependencies(
      requirements_to_unlock: update_strategy
    )

    return if updated_deps.empty?

    # Determine version change type
    old_version = dep.version
    new_version = updated_deps.first.version
    change_type = determine_change_type(old_version, new_version)

    # Filter based on update strategy
    case update_strategy
    when :none # patch_only
      return unless change_type == "patch"
    when :own # minor_and_patch
      return if change_type == "major"
    when :all # all updates allowed
      # Allow all updates
    end

    puts "✨ Update available for #{dep.name}: #{dep.version} -> #{updated_deps.first.version}"
    all_updated_deps.concat(updated_deps)

    strategy_label = case update_strategy
                    when :none then "(patch)"
                    when :own then "(minor)"
                    when :all then "(major)"
                    end

    update_info = {
      name: dep.name,
      old_version: old_version,
      new_version: new_version,
      change_type: change_type,
      strategy: strategy_label,
      is_dev_dep: is_dev_dep,
      dependency: updated_deps.first
    }

    update_summaries << update_info
  end

  def determine_change_type(old_version, new_version)
    old_parts = old_version.split('.').map(&:to_i)
    new_parts = new_version.split('.').map(&:to_i)

    return "major" if old_parts[0] != new_parts[0]
    return "minor" if old_parts[1] != new_parts[1]
    return "patch"
  end

  def analyze_successful_updates_with_ai(successful_updates)
    unless @openrouter_api_key
      puts "⚠️  Warning: OPENROUTER_API_KEY not set - skipping AI analysis"
      return nil
    end

    return nil unless @config.dig("settings", "ai_analysis", "enabled")

    puts "🤖 Analyzing #{successful_updates[:deps].length} successful updates with AI via #{@analysis_model}..."

    # Check GitHub rate limit before fetching changelogs
    check_github_rate_limit_status

    # Prepare update information for AI with local changelogs - ONLY for successful updates
    # Process changelogs
    update_details = successful_updates[:summaries].map do |update|
      process_update_info_with_changelog(update)
    end.join("\n")

    prompt = build_ai_prompt(update_details)

    begin
      response = make_openrouter_request(@analysis_model, prompt)

      if response
        puts "✅ AI analysis completed"
        puts "📊 AI Analysis Result:"
        puts "=" * 50
        puts response
        puts "=" * 50
        return response
      else
        puts "❌ AI analysis failed"
        return nil
      end
    rescue => e
      puts "❌ AI analysis error: #{e.message}"
      return nil
    end
  end

  def process_update_info_with_changelog(update)
    base_info = "- #{update[:name]}: #{update[:old_version]} → #{update[:new_version]} (#{update[:change_type]}) #{update[:strategy]} #{update[:is_dev_dep] ? '[dev]' : '[prod]'}"

    # Skip changelog for patch versions for performance
    if update[:change_type] == "patch"
      puts "⏭️  Skipping changelog for #{update[:name]} (patch update)"
      return "#{base_info}\n  📋 Changelog skipped for patch version"
    end

    puts "🔍 Processing changelog for #{update[:name]} (#{update[:change_type]} update)"
    changelog = get_dependabot_changelog(update[:name], update[:old_version], update[:new_version], update[:dependency])

    if changelog
      "#{base_info}\n  📋 Changelog (#{update[:old_version]} → #{update[:new_version]}):\n#{changelog}"
    else
      "#{base_info}\n  📋 No changelog available"
    end
  end

  def get_dependabot_changelog(package_name, old_version, new_version, dependency)
    return nil unless dependency

    # Install updated dependencies to get latest changelogs in node_modules
    puts "📦 Installing updated dependencies to access latest changelogs..."
    unless system("npm install > /dev/null 2>&1")
      puts "⚠️  Warning: npm install failed, may affect local changelog reading"
    end

    # First try: Use Dependabot's metadata finder (works for public packages)
    changelog = get_remote_changelog(package_name, dependency)

    # Second try: Fallback to local node_modules changelog
    if !changelog
      puts "⏭️  No changelog found for #{package_name} - trying local changelog"
      changelog = get_local_changelog(package_name, old_version, new_version, dependency)
    end

    return changelog
  end

  def get_remote_changelog(package_name, dependency)
    begin
      # Create metadata finder for npm packages
      source = Dependabot::Source.new(
        provider: "gitlab",
        repo: @project_path
      )

      metadata_finder = Dependabot::MetadataFinders.for_package_manager("npm_and_yarn").new(
        dependency: dependency,
        credentials: get_credentials
      )

      # Get changelog URL and content
      changelog_url = metadata_finder.changelog_url
      return nil unless changelog_url

      puts "📋 Found changelog URL for #{package_name}: #{changelog_url}"

      # Get the changelog text
      changelog_text = metadata_finder.changelog_text
      return nil unless changelog_text

      # Use Dependabot's changelog pruner to extract relevant section
      pruner = Dependabot::MetadataFinders::Base::ChangelogPruner.new(
        changelog_text: changelog_text,
        dependency: dependency
      )

      relevant_changelog = pruner.pruned_text

      if relevant_changelog && !relevant_changelog.strip.empty?
        # Limit size for AI analysis
        if relevant_changelog.length > @changelog_token_limit
          relevant_changelog = relevant_changelog[0..@changelog_token_limit-3] + "..."
          puts "📋 Truncated changelog for #{package_name} (too long)"
        end

        puts "📋 Successfully retrieved remote changelog for #{package_name}"
        return relevant_changelog
      else
        puts "⚠️  No relevant changelog content found remotely for #{package_name}"
        return nil
      end

    rescue => e
      error_msg = e.message.downcase
      if error_msg.include?("rate limit") || error_msg.include?("api rate limit exceeded")
        puts "🚫 GitHub API rate limit exceeded for #{package_name}"
        @rate_limited_packages << package_name unless @rate_limited_packages.include?(package_name)
        return nil
      else
        puts "⚠️  Error retrieving remote changelog for #{package_name}: #{e.message}"
        return nil
      end
    end
  end

  def get_local_changelog(package_name, old_version, new_version, dependency)
    # Try to find changelog in node_modules
    possible_paths = [
      "node_modules/#{package_name}/CHANGELOG.md",
      "node_modules/#{package_name}/CHANGELOG.txt",
      "node_modules/#{package_name}/HISTORY.md",
      "node_modules/#{package_name}/CHANGES.md",
      "node_modules/#{package_name}/NEWS.md",
      "node_modules/#{package_name}/changelog.md",
      "node_modules/#{package_name}/history.md"
    ]

    changelog_file = possible_paths.find { |path| File.exist?(path) }

    unless changelog_file
      puts "⚠️  No local changelog found for #{package_name} in node_modules"
      return nil
    end

    begin
      puts "📋 Found local changelog for #{package_name}: #{changelog_file}"
      changelog_content = File.read(changelog_file)

      # Use Dependabot's changelog pruner to extract relevant section (same as remote)
      pruner = Dependabot::MetadataFinders::Base::ChangelogPruner.new(
        changelog_text: changelog_content,
        dependency: dependency
      )

      relevant_changelog = pruner.pruned_text

      if relevant_changelog && !relevant_changelog.strip.empty?
        # Limit size for AI analysis
        if relevant_changelog.length > @changelog_token_limit
          relevant_changelog = relevant_changelog[0..@changelog_token_limit-3] + "..."
          puts "📋 Truncated local changelog for #{package_name} (too long)"
        end

        puts "📋 Successfully extracted changelog section for #{package_name} (#{old_version} → #{new_version})"
        return relevant_changelog
      else
        puts "⚠️  No relevant version section found in local changelog for #{package_name}"
        return nil
      end

    rescue => e
      puts "⚠️  Error reading local changelog for #{package_name}: #{e.message}"
      return nil
    end
  end

  def build_ai_prompt(update_details)
    """
    You are an expert Node.js/React developer analyzing dependency updates for potential breaking changes.

    Analyze these dependency updates (changelogs included where available):

    #{update_details}

    For packages with changelogs provided, use that information to give specific analysis.
    For packages without changelogs, provide general guidance based on version changes.

    Provide a concise analysis in markdown format covering:

    ## 🎯 Risk Assessment
    Rate overall risk as HIGH/MEDIUM/LOW and briefly explain why.

    ## ⚠️ Breaking Changes & Migration
    For each dependency with potential issues:
    - Highlight breaking changes (API, config, behavior) based on changelogs when available
    - Include migration steps if needed
    - Reference specific changelog entries when provided
    - For private packages, focus on changelog details provided

    Keep it concise but actionable. Focus on what developers need to know and do.
    """
  end

  def make_openrouter_request(model, prompt)
    uri = URI("https://openrouter.ai/api/v1/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@openrouter_api_key}"
    request["Content-Type"] = "application/json"
    request["HTTP-Referer"] = "#{@gitlab_host}/#{@project_path}"
    request["X-Title"] = "Dependabot AI Analysis"

    payload = {
      model: model,
      messages: [
        {
          role: "system",
          content: "You are an expert software engineer specializing in dependency management and breaking change analysis for Node.js/React applications."
        },
        {
          role: "user",
          content: prompt
        }
      ],
      max_tokens: 2000,
      temperature: 0.3
    }

    request.body = payload.to_json

    response = http.request(request)

    if response.code == "200"
      result = JSON.parse(response.body)
      return result.dig("choices", 0, "message", "content")
    else
      puts "OpenRouter API error: #{response.code} - #{response.body}"
      return nil
    end
  end

  def load_config
    if File.exist?(".dependabotrc.mjs")
      puts "📋 Loading configuration from .dependabotrc.mjs"
      result = nil

      begin
        result = Timeout::timeout(10) do
          `node -e "import('./.dependabotrc.mjs').then(config => console.log(JSON.stringify(config.default))).catch(err => console.error('Error:', err.message))" 2>&1`
        end
      rescue Timeout::Error
        puts "❌ Timeout loading .dependabotrc.mjs, using defaults"
        result = nil
      end

      puts "⚙️ Loaded configuration: #{result.inspect}" if result

      if result && !result.strip.empty? && $?.success?
        begin
          config = JSON.parse(result.strip)
          puts "✅ Configuration loaded successfully"
          return config
        rescue JSON::ParserError => e
          puts "❌ JSON parse error in .dependabotrc.mjs: #{e.message}"
          puts "❌ Raw output: #{result.inspect}"
        end
      else
        puts "❌ Node.js failed to load .dependabotrc.mjs"
        puts "❌ Exit code: #{$?.exitstatus}" if $?
        puts "❌ Output: #{result.inspect}" if result
      end
    else
      puts "⚠️  No .dependabotrc.mjs found, using defaults"
    end

    # Default configuration
    puts "📋 Using default configuration"
    {
      "settings" => {
        "target_branch" => @target_branch,
        "mr_assignee_username" => @mr_assignee_username,
        "update_strategy" => "minor_and_patch",
        "ai_analysis" => {
          "enabled" => true,
          "model" => @analysis_model
        }
      },
      "dependencies" => {
        "ignore" => ["eslint"],
        "patch_only" => ["react", "react-dom"],
        "minor_updates" => ["lodash", "axios", "date-fns"],
        "major_updates" => ["@types/*"]
      },
      "dev_dependencies" => {
        "update_strategy" => "all",
        "ignore" => ["webpack"],
        "patch_only" => [],
        "minor_updates" => [],
        "major_updates" => []
      }
    }
  end

  private

  def record_step_time(step_name, start_time)
    duration = Time.now - start_time
    @step_timings[step_name] = duration
    puts "⏱️  #{step_name}: #{format_duration(duration)}"
  end

  def format_duration(seconds)
    if seconds < 1
      "#{(seconds * 1000).round}ms"
    elsif seconds < 60
      "#{seconds.round(1)}s"
    elsif seconds < 3600
      minutes = (seconds / 60).floor
      remaining_seconds = (seconds % 60).round
      "#{minutes}m #{remaining_seconds}s"
    else
      hours = (seconds / 3600).floor
      remaining_minutes = ((seconds % 3600) / 60).floor
      "#{hours}h #{remaining_minutes}m"
    end
  end

  def print_timing_summary
    total_time = Time.now - @start_time
    puts ""
    puts "📊 Timing Summary:"
    puts "=" * 50

    @step_timings.each do |step, duration|
      percentage = (duration / total_time * 100).round(1)
      puts "  #{step.ljust(25)} #{format_duration(duration).rjust(8)} (#{percentage.to_s.rjust(5)}%)"
    end

    puts "  #{'─' * 35}"
    puts "  #{'Total Time'.ljust(25)} #{format_duration(total_time).rjust(8)} (100.0%)"
    puts "=" * 50
  end
end

if __FILE__ == $0
  bot = nil
  begin
    bot = DependabotWithAI.new
    success = bot.run
    exit(success ? 0 : 1)
  rescue => e
    puts "💥 Fatal error: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    exit 1
  end
end
