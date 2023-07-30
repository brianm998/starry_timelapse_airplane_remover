# coding: utf-8
#

Pod::Spec.new do |s|

  s.name         = "StarCore"
  s.version      = "0.1.2"
  s.summary      = "star"

  s.description  = <<-DESC
  star code (add more here)
                   DESC

  s.homepage     = "http://brianinthe.cloud"
  s.license      = "GPL"

  s.author       = { "" => "" }
  s.platforms    = { :osx =>  "12.0" }

  s.source       = { :git => "git@github.com:brianm998/nighttime_timelapse_airplane_remover", :branch => "develop" }
  s.source_files  = "Sources/**/*.{swift}"
  s.exclude_files = "Sources/star/Star.swift"

  s.dependency 'ShellOut', '~> 2.0'
  
  s.pod_target_xcconfig = { 'SWIFT_VERSION' => 5 }

end
