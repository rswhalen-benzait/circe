import Foundation
@testable import CirceVNC

func runDesktopDiscoveryTests() {
    run("Desktop discovery deduplicates listener addresses") {
        let json = #"{"user":"u","os":{"id":"ubuntu","like":"debian","name":"Ubuntu"},"packageManager":"apt","sudo":"none","adminGroup":false,"systemd":true,"ffmpeg":false,"circe":{"installed":true,"display":1,"running":true},"vnc":[{"port":5903,"display":3,"address":"[::1]","loopback":true,"rfb":true,"process":"Xvnc"},{"port":5903,"display":3,"address":"127.0.0.1","loopback":true,"rfb":true,"process":"Xvnc"},{"port":5901,"display":1,"address":"127.0.0.1","loopback":true,"rfb":true,"process":"Xtigervnc"},{"port":5900,"display":0,"address":"127.0.0.1","loopback":true,"rfb":true,"process":"wayvnc"},{"port":5910,"display":10,"address":"127.0.0.1","loopback":true,"rfb":false,"process":"python"},{"port":5908,"display":8,"address":"0.0.0.0","loopback":false,"rfb":true,"process":"Xvnc"},{"port":5909,"display":0,"address":"127.0.0.1","loopback":true,"rfb":true,"process":"Xvnc"}],"sessions":[]}"#
        let probe = try JSONDecoder().decode(LinuxSetup.Probe.self, from: Data(json.utf8))
        expect(probe.existingDesktops.map(\.display) == [0, 3])
        expect(probe.existingDesktops.last?.address == "127.0.0.1")
        expect(probe.existingDesktops.first?.process == "wayvnc")
    }
}
