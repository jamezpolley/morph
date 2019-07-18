set :application, 'morph'
set :repo_url, 'https://github.com/openaustralia/morph.git'

set :rvm_ruby_version, '2.3.1'

# ask :branch, proc { `git rev-parse --abbrev-ref HEAD`.chomp }

set :deploy_to, '/var/www'
# set :scm, :git

# set :format, :pretty
# set :log_level, :debug
# set :pty, true

set :linked_files, %w{config/database.yml config/sync.yml .env}
set :linked_dirs, %w{db/scrapers public/sitemaps tmp/pids log}
# set :linked_dirs, %w{bin log tmp/pids tmp/cache tmp/sockets vendor/bundle public/system}

# set :default_env, { path: "/opt/ruby/bin:$PATH" }
# set :keep_releases, 5

namespace :deploy do

  desc 'Restart application'
  task :restart do
    on roles(:app), in: :sequence, wait: 5 do
      # Your restart mechanism here, for example:
      execute :touch, release_path.join('tmp/restart.txt')
    end
  end

  after :restart, :clear_cache do
    on roles(:web), in: :groups, limit: 3, wait: 10 do
      # Here we can do anything such as:
      # within release_path do
      #   execute :rake, 'cache:clear'
      # end
    end
  end

  after :finishing, 'deploy:cleanup'

  desc "Build docker images"
  task :docker do
    on roles(:app) do
      within release_path do
        execute :bundle, "exec rake app:update_docker_image RAILS_ENV=production"
      end
    end
  end
end

namespace :foreman do
  desc "Start the application services"
  task :start do
    on roles(:app) do
      sudo "systemctl start morph.target"
    end
  end

  desc "Stop the application services"
  task :stop do
    on roles(:app) do
      sudo "systemctl stop morph.target"
    end
  end

  desc "Restart the application services"
  task :restart do
    on roles(:app) do
      sudo "systemctl restart morph.target"
    end
  end
end

namespace :searchkick do
  namespace :reindex do
    desc "Reindex all models"
    task :all do
      on roles(:app) do
        within release_path do
          execute :bundle, "exec rake searchkick:reindex:all RAILS_ENV=production"
        end
      end
    end
  end
end

# TODO: Hmmm... Need to think about the best order for doing these
after 'deploy:publishing', 'deploy:restart'
before "deploy:restart", "deploy:docker"
after "deploy:docker", "foreman:restart"
# Disable the searchkick reindex on deploys because it just takes *way* too long
# However, not that on a first deploy you do need to run the searchkick:reindex:all
# task otherwise things won't work as expected
#after "foreman:restart", "searchkick:reindex:all"
