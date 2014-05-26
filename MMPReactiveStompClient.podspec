Pod::Spec.new do |s|
  s.name             = "MMPReactiveStompClient"
  s.version          = "0.1.0"
  s.summary          = "A reactive WebSocket/STOMP client based on ReactiveCocoa"
  s.description      = <<-DESC
                       MMPReactiveStompClient is a reactive WebSocket/STOMP client library based on ReactiveCocoa and SocketRocket. 

                       Features:
                       * Signal for raw WebSocket.
                       * Signal for STOMP frames, messages, and subscription. 
                       DESC
  s.homepage         = "https://github.com/mpurbo/MMPReactiveStompClient"
  s.license          = 'MIT'
  s.author           = { "Mamad Purbo" => "m.purbo@gmail.com" }
  s.source           = { :git => "https://github.com/mpurbo/MMPReactiveStompClient.git", :tag => s.version.to_s }
  s.social_media_url = 'https://twitter.com/purubo'

  s.platform         = :ios
  s.ios.deployment_target = '5.0'
  s.source_files     = 'Classes'
  s.dependency 'ReactiveCocoa'
  s.dependency 'SocketRocket'
  s.requires_arc     = true    
end
