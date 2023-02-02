# coding: utf-8
#

Pod::Spec.new do |s|

  s.name         = "NtarCore"
  s.version      = "0.1.2"
  s.summary      = "ntar"

  s.description  = <<-DESC
  ntar code (add more here)
                   DESC

  s.homepage     = "http://brianinthe.cloud"
  s.license      = "GPL"

  s.author       = { "" => "" }
  s.platforms    = { :osx =>  "10.15" }

  s.source       = { :git => "git@github.com:brianm998/nighttime_timelapse_airplane_remover", :branch => "develop" }
  s.source_files  = "Sources/**/*.{swift}"
  s.exclude_files = "Sources/ntar/Ntar.swift"

  s.pod_target_xcconfig = { 'SWIFT_VERSION' => 5 }

end
