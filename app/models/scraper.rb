# frozen_string_literal: true

# A scraper is a script that runs that gets data from the web
class Scraper < ActiveRecord::Base
  include Sync::Actions
  # Using smaller batch_size than the default for the time being because
  # reindexing causes elasticsearch on the local VM to run out of memory
  # defaults to 1000
  searchkick word_end: [:scraped_domain_names], word_middle: [:full_name],
             batch_size: 100

  belongs_to :owner, inverse_of: :scrapers
  belongs_to :forked_by, class_name: "User"

  has_many :runs, inverse_of: :scraper, dependent: :destroy
  has_many :metrics, through: :runs
  has_many :contributors, through: :contributions, source: :user
  has_many :contributions, dependent: :delete_all
  has_many :watches, class_name: "Alert", foreign_key: :watch_id, dependent: :delete_all
  has_many :watchers, through: :watches, source: :user
  belongs_to :create_scraper_progress, dependent: :delete
  has_many :variables, dependent: :delete_all
  accepts_nested_attributes_for :variables, allow_destroy: true
  has_many :webhooks, dependent: :destroy
  accepts_nested_attributes_for :webhooks, allow_destroy: true
  validates_associated :variables
  delegate :sqlite_total_rows, to: :database
  has_one :last_run, -> { order "queued_at DESC" }, class_name: "Run"

  has_many :api_queries, dependent: :delete_all

  validates :name, presence: true, format: {
    with: /\A[a-zA-Z0-9_-]+\z/,
    message: "can only have letters, numbers, '_' and '-'"
  }
  validates :owner, presence: true
  validates :name, uniqueness: {
    scope: :owner, message: "is already taken on morph.io"
  }
  validate :not_used_on_github, on: :create, if: -> { github_id.blank? && !name.blank? }
  with_options if: -> { scraperwiki_shortname || scraperwiki_url },
               on: :create do |s|
    s.validate :exists_on_scraperwiki
    s.validate :public_on_scraperwiki
    s.validate :not_scraperwiki_view
  end

  extend FriendlyId
  friendly_id :full_name

  delegate :finished_recently?, :finished_at, :finished_successfully?,
           :finished_with_errors?, :queued?, :running?, :stop!,
           to: :last_run, allow_nil: true

  # Give a count of the total number of scrapers rounded down to the nearest
  # hundred so that you can say "more than ... scrapers"
  def self.rounded_count
    floor_to_hundreds(count)
  end

  def self.floor_to_hundreds(number)
    (number / 100.0).floor * 100
  end

  def self.running
    Run.running.map(&:scraper).compact
  end

  def search_data
    {
      full_name: full_name,
      description: description,
      scraped_domain_names: scraped_domain_names,
      data?: data?
    }
  end

  def data?
    sqlite_total_rows.positive?
  end

  def scraped_domain_names
    scraped_domains.map(&:name)
  end

  def scraped_domains
    last_run ? last_run.domains : []
  end

  def all_watchers
    (watchers + owner.watchers).uniq
  end

  # Also orders the owners by number of downloads
  def download_count_by_owner
    # TODO: Simplify this by using an association on api_query
    count_by_owner_id = api_queries
                        .group(:owner_id)
                        .order("count_all desc")
                        .count
    count_by_owner_id.map do |id, count|
      [Owner.find(id), count]
    end
  end

  def download_count
    api_queries.count
  end

  # Given a scraper name on github populates the fields for a morph.io scraper
  # but doesn't save it
  def self.new_from_github(full_name, octokit_client)
    repo = octokit_client.repository(full_name)
    repo_owner = Owner.find_by_nickname(repo.owner.login)
    # Populate a new scraper with information from the repo
    Scraper.new(
      name: repo.name, full_name: repo.full_name, description: repo.description,
      github_id: repo.id, owner_id: repo_owner.id,
      github_url: repo.rels[:html].href, git_url: repo.rels[:git].href
    )
  end

  # Find a user related to this scraper that we can use them to make
  # authenticated github requests
  def related_user
    if owner.user?
      owner
    else
      owner.users.first
    end
  end

  def original_language
    Morph::Language.new(original_language_key.to_sym)
  end

  def update_contributors
    nicknames = Morph::Github.contributor_nicknames(full_name, related_user)
    contributors = nicknames.map { |n| User.find_or_create_by_nickname(n) }
    update_attributes(contributors: contributors)
  end

  def successful_runs
    runs.order(finished_at: :desc).finished_successfully
  end

  def latest_successful_run_time
    latest_successful_run = successful_runs.first
    latest_successful_run&.finished_at
  end

  def finished_runs
    runs.where("finished_at IS NOT NULL").order(finished_at: :desc)
  end

  # For successful runs calculates the average wall clock time that this scraper
  # takes. Handy for the user to know how long it should expect to run for
  # Returns nil if not able to calculate this
  # TODO: Refactor this using scopes
  def average_successful_wall_time
    return if successful_runs.count.zero?

    successful_runs.sum(:wall_time) / successful_runs.count
  end

  def total_wall_time
    runs.to_a.sum(&:wall_time)
  end

  def utime
    metrics.sum(:utime)
  end

  def stime
    metrics.sum(:stime)
  end

  def cpu_time
    utime + stime
  end

  def update_sqlite_db_size
    update_attributes(sqlite_db_size: database.sqlite_db_size)
  end

  def total_disk_usage
    repo_size + sqlite_db_size
  end

  # Let's say a scraper requires attention if it's set to run automatically and
  # the last run failed
  # TODO: This is now inconsistent with the way this is handled elsewhere
  def requires_attention?
    auto_run && last_run && last_run.finished_with_errors?
  end

  def self.can_write?(user, owner)
    user && (owner == user || user.organizations.include?(owner))
  end

  def can_write?(user)
    Scraper.can_write?(user, owner)
  end

  def destroy_repo_and_data
    FileUtils.rm_rf repo_path
    FileUtils.rm_rf data_path
  end

  def repo_path
    "#{owner.repo_root}/#{name}"
  end

  def data_path
    "#{owner.data_root}/#{name}"
  end

  def readme
    f = Dir.glob(File.join(repo_path, "README*")).first
    GitHub::Markup.render(f, File.read(f)).html_safe if f
  end

  def readme_filename
    Pathname.new(Dir.glob(File.join(repo_path, "README*")).first).basename.to_s
  end

  def github_url_readme
    github_url_for_file(readme_filename)
  end

  def runnable?
    last_run.nil? || last_run.finished?
  end

  def queue!
    # Guard against more than one of a particular scraper running at the
    # same time
    return unless runnable?

    run = runs.create(queued_at: Time.now, auto: false, owner_id: owner_id)
    RunWorker.perform_async(run.id)
  end

  def github_url_for_file(file)
    github_url + "/blob/master/" + file
  end

  def language
    Morph::Language.language(repo_path)
  end

  def main_scraper_filename
    language&.scraper_filename
  end

  def github_url_main_scraper_file
    github_url_for_file(main_scraper_filename)
  end

  def database
    Morph::Database.new(data_path)
  end

  def platform
    platform_file = "#{repo_path}/platform"
    platform = if File.exist?(platform_file)
                 File.read(platform_file)
               else
                 "latest"
               end
    platform.chomp
  end

  # It seems silly implementing this
  def self.directory_size(directory)
    r = 0
    if File.exist?(directory)
      # Ick
      files = Dir.entries(directory)
      files.delete(".")
      files.delete("..")
      files.map { |f| File.join(directory, f) }.each do |f|
        s = File.lstat(f)
        r += if s.file?
               s.size
             else
               Scraper.directory_size(f)
             end
      end
    end
    r
  end

  def update_repo_size
    r = Scraper.directory_size(repo_path)
    update_attribute(:repo_size, r)
    r
  end

  def scraperwiki_shortname
    # scraperwiki_url should be of the form https://classic.scraperwiki.com/scrapers/shortname/
    return if scraperwiki_url.nil?

    m = scraperwiki_url.match(
      %r{https://classic.scraperwiki.com/scrapers/([-\w]+)(/)?}
    )
    m[1] if m
  end

  def scraperwiki_shortname=(shortname)
    return if shortname.blank?

    self.scraperwiki_url =
      "https://classic.scraperwiki.com/scrapers/#{shortname}/"
  end

  def current_revision_from_repo
    r = Grit::Repo.new(repo_path)
    Grit::Head.current(r).commit.id
  end

  # files should be a hash of "filename" => "content"
  def add_commit_to_master_on_github(user, files, message)
    client = user.octokit_client
    blobs = files.map do |filename, content|
      {
        path: filename,
        mode: "100644",
        type: "blob",
        content: content
      }
    end

    # Let's get all the info about head
    ref = client.ref(full_name, "heads/master")
    commit_sha = ref.object.sha
    commit = client.commit(full_name, commit_sha)
    tree_sha = commit.commit.tree.sha

    tree2 = client.create_tree(full_name, blobs, base_tree: tree_sha)
    commit2 = client.create_commit(full_name, message, tree2.sha, commit_sha)
    client.update_ref(full_name, "heads/master", commit2.sha)
  end

  # Overwrites whatever there was before in that repo
  # Obviously use with great care
  def add_commit_to_root_on_github(user, files, message)
    client = user.octokit_client
    blobs = files.map do |filename, content|
      {
        path: filename,
        mode: "100644",
        type: "blob",
        content: content
      }
    end
    tree = client.create_tree(full_name, blobs)
    commit = client.create_commit(full_name, message, tree.sha)
    client.update_ref(full_name, "heads/master", commit.sha)
  end

  def synchronise_repo
    Morph::Github.synchronise_repo(repo_path, git_url)
    update_repo_size
    update_contributors
  rescue Grit::Git::CommandFailed => e
    puts "git command failed: #{e}"
    puts "Ignoring and moving onto the next one..."
  end

  # Return the https version of the git clone url (git_url)
  def git_url_https
    "https" + git_url[3..-1]
  end

  def fork_from_scraperwiki!
    client = forked_by.octokit_client

    # We need to set auto_init so that we can create a commit later.
    # The API doesn't support adding a commit to an empty repository
    begin
      create_scraper_progress.update("Creating GitHub repository", 20)
      repo = Morph::Github.create_repository(forked_by, owner, name)
      update_attributes(github_id: repo.id, github_url: repo.rels[:html].href,
                        git_url: repo.rels[:git].href)
    # rubocop:disable Lint/HandleExceptions
    rescue Octokit::UnprocessableEntity
      # This means the repo has already been created. We will have gotten here
      # if this background job failed at some point past here and is rerun. So,
      # let's happily continue
    end
    # rubocop:enable Lint/HandleExceptions

    scraperwiki = Morph::Scraperwiki.new(scraperwiki_shortname)

    # Copy the sqlite database across from Scraperwiki
    create_scraper_progress.update("Forking sqlite database", 40)
    sqlite_data = scraperwiki.sqlite_database
    if sqlite_data
      database.write_sqlite_database(sqlite_data)
      # Rename the main table in the sqlite database
      if database.valid?
        database.standardise_table_name("swdata")
      else
        # If the data was corrupt when loading from Scraperwiki then just
        # delete our local copy here. Much simpler for the user.
        database.clear
      end
    end

    create_scraper_progress.update("Forking code", 60)

    # Fill in description
    client.edit_repository(
      full_name,
      description: scraperwiki.title,
      homepage: Rails.application.routes.url_helpers.scraper_url(self)
    )
    update_attributes(description: scraperwiki.title)

    files = {
      scraperwiki.language.scraper_filename => scraperwiki.code,
      ".gitignore" =>
        "# Ignore output of scraper\n#{Morph::Database.sqlite_db_filename}\n"
    }
    files["README.textile"] = scraperwiki.description unless scraperwiki.description.blank?
    add_commit_to_root_on_github(
      forked_by, files,
      "Fork of code from ScraperWiki at #{scraperwiki_url}"
    )

    # Add another commit (but only if necessary) to translate the code so it
    # runs here
    unless scraperwiki.translated_code == scraperwiki.code
      add_commit_to_master_on_github(
        forked_by,
        { scraperwiki.language.scraper_filename => scraperwiki.translated_code },
        "Automatic update to make ScraperWiki scraper work on morph.io"
      )
    end

    create_scraper_progress.update("Synching repository", 80)
    synchronise_repo

    # Forking has finished
    create_scraper_progress.finished

    # TODO: Add repo link
  end

  def deliver_webhooks(run)
    webhooks.each do |webhook|
      webhook_delivery = webhook.deliveries.create!(run: run)
      DeliverWebhookWorker.perform_async(webhook_delivery.id)
    end
  end

  private

  def not_used_on_github
    return unless Octokit.repository?(full_name)

    errors.add(:name, "is already taken on GitHub")
  end

  def exists_on_scraperwiki
    return if Morph::Scraperwiki.new(scraperwiki_shortname).exists?

    errors.add(:scraperwiki_shortname, "doesn't exist on ScraperWiki")
  end

  def public_on_scraperwiki
    return unless Morph::Scraperwiki.new(scraperwiki_shortname).private_scraper?

    errors.add(:scraperwiki_shortname,
               "needs to be a public scraper on ScraperWiki")
  end

  def not_scraperwiki_view
    return unless Morph::Scraperwiki.new(scraperwiki_shortname).view?

    errors.add(:scraperwiki_shortname, "can't be a ScraperWiki view")
  end
end
