Pod::Spec.new do |s|
  s.name             = "APIncrementalStore"
  s.version          = "0.4.0"
  s.summary          = "Apple NSIncrementalStore subclass that implements local cache and sync to remote BaaS."
  s.homepage         = "https://github.com/flavionegrao/APIncrementalStore"
  s.license          = 'MIT'
  s.author           = { "Flavio Negrao Torres" => "flavio@apetis.com" }

  s.source           = { :git => "https://github.com/flavionegrao/APIncrementalStore.git", :tag => "#{s.version}" }
  s.source_files     = "APIncrementalStore/**"
  
  s.framework  = 'CoreData'

  s.ios.deployment_target = '6.0'
  s.ios.dependency 'Parse-iOS-SDK'

  s.requires_arc = true

end
