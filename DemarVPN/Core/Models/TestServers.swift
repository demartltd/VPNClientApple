import Foundation

enum TestServers {
    static let uris: [String] = [
        "vless://60ff5afd-c854-42cc-ab4d-c7b4c8b1e476@89.169.34.117:443?security=reality&type=tcp&headerType=&path=&host=&sni=medicaltourismfinland.com&fp=chrome&pbk=F7lqLieNYO_tFZxjyfNU1ngPstIq-COYfWIPmNTozU0&sid=0b8867648ade21db#%F0%9F%9A%80%20Marz%20%28test1%29%20%5BVLESS%20-%20tcp%5D",
        "vless://ed98edee-1174-434f-a15d-7b8dfd384a95@89.169.34.117:55699?security=reality&type=tcp&headerType=&path=&host=&sni=ads.x5.ru&fp=chrome&pbk=F7lqLieNYO_tFZxjyfNU1ngPstIq-COYfWIPmNTozU0&sid=0b8867648ade21db#%F0%9F%9A%80%20Marz%20%28test%29%20%5BVLESS%20-%20tcp%5D",
    ]

    static var profiles: [ServerProfile] {
        uris.map { ServerProfile(uri: $0) }
    }
}
