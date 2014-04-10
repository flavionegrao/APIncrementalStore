Pod::Spec.new do |s|
  s.name             = "APIncrementalStore"
  s.version          = "0.1.0"
  s.summary          = "Apple NSIncrementalStore subclass that implements local cache and sync to remote BaaS."
  s.homepage         = "https://github.com/flavionegrao/APIncrementalStore"
  s.license          = 'MIT'
  s.author           = { "Flavio Negrao Torres" => "flavio@apetis.com" }
  s.source           = { :git => "https://github.com/flavionegrao/APIncrementalStore.git", :tag => s.version.to_s }
  
  s.framework  = 'CoreData'

  s.ios.deployment_target = '5.0'
  s.requires_arc = true

end