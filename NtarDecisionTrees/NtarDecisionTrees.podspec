# coding: utf-8
#

Pod::Spec.new do |s|

  s.name         = "NtarDecisionTrees"
  s.version      = "0.1.2"
  s.summary      = "ntar auto generated decision trees"

  s.description  = <<-DESC
  ntar decision trees for deciding the paintability of outlier groups
  There may be many different trees here, and they can be large,
  separating them to keep the long compile times limited to here.
                   DESC

  s.homepage     = "http://brianinthe.cloud"
  s.license      = "GPL"

  s.author       = { "" => "" }
  s.platforms    = { :osx =>  "10.15" }

  s.source       = { :git => "git@github.com:brianm998/nighttime_timelapse_airplane_remover", :branch => "develop" }
  s.source_files  = "Sources/**/*.{swift}"
  s.exclude_files = "Sources/ntar/Ntar.swift"

  s.dependency 'NtarCore'
  
  s.pod_target_xcconfig = { 'SWIFT_VERSION' => 5 }

end
