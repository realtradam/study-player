stack_root = ENV['JAMSTACK_ROOT'] || File.expand_path('../../..', __dir__)
raylib_inc = File.join(stack_root, 'vendor', 'raylib', 'src')

MRuby::Gem::Specification.new('study_audio') do |spec|
  spec.license = 'MIT'
  spec.authors = 'raylib-jamstack'
  spec.summary = 'Ruby (StudyAudio) native helper: loads raw float samples from audio files via raylib Wave API'

  spec.cc.include_paths << raylib_inc
end
