Gem::Specification.new do |gem|
  gem.name = 'ar_sendmail_rails3'
  gem.version = '2.1.11'
  gem.authors = ['Yuanyi Zhang']
  gem.email = %w(leschenko.al@gmail.com)
  gem.summary = %q{ArMailer wrapper for Rails 3}
  gem.description = %q{ArMailer wrapper for Rails 3}
  gem.homepage = 'https://github.com/leschenko/ar_sendmail_rails3'

  gem.files = `git ls-files`.split($/)
  gem.executables = gem.files.grep(%r{^bin/}).map { |f| File.basename(f) }
  gem.test_files = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = %w(lib)

  gem.add_development_dependency 'rspec'
end
