#
# Be sure to run `pod lib lint KKFlutterInspectorKit.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'KKFlutterInspectorKit'
  s.version          = '0.1.0'
  s.summary          = 'An iOS toolkit for inspecting Flutter integration.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
  KKFlutterInspectorKit provides reusable Objective-C components for
  inspecting and debugging Flutter content embedded in iOS applications.
  DESC
  
  s.homepage         = 'https://github.com/kriskicekk/KKFlutterInspectorKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'kriskicekk' => 'kriskice9527@gmail.com' }
  s.source           = {
      :git => 'https://github.com/kriskicekk/KKFlutterInspectorKit.git',
      :tag => s.version.to_s
  }
  s.ios.deployment_target = '13.0'
  s.source_files = 'KKFlutterInspectorKit/Classes/**/*.{h,m,mm}'
  s.public_header_files = [
    'KKFlutterInspectorKit/Classes/KKFlutterInspector.h',
    'KKFlutterInspectorKit/Classes/Internal/Model/KKFIInspectorModels.h'
  ]
  s.private_header_files = [
    'KKFlutterInspectorKit/Classes/Internal/Connection/*.h',
    'KKFlutterInspectorKit/Classes/Internal/Hierarchy/*.h',
    'KKFlutterInspectorKit/Classes/Internal/Inspector/*.h',
    'KKFlutterInspectorKit/Classes/Internal/Runtime/*.h',
    'KKFlutterInspectorKit/Classes/Internal/Session/*.h'
  ]
  s.frameworks = 'Foundation', 'UIKit'
end
