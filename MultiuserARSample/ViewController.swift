//
//  ViewController.swift
//  MultiuserARSample
//
//  Created by 長政輝 on 2022/11/17.
//

import UIKit
import RealityKit
import ARKit
import MultipeerSession

class ViewController: UIViewController {
    
    @IBOutlet var arView: ARView!
    
    var multipeerSession: MultipeerSession?
    var sessionIDObserbation: NSKeyValueObservation?
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        setupARView()
        
        setupMultipeerSession()
        
        arView.session.delegate = self
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(recognizer:)))
        arView.addGestureRecognizer(tapGestureRecognizer)
    }
    
    func setupARView() {
        arView.automaticallyConfigureSession = false
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        
        config.isCollaborationEnabled = true
        
        arView.session.run(config)
    }
    
    func setupMultipeerSession() {
        // ARSessionの識別子を監視するために、key-value観測を使用します。
        sessionIDObserbation = observe(\.arView.session.identifier, options: [.new]) { object, change in
            print("SessionID chaged to: \(change.newValue!)")
            
            // 他のすべてのピアに、あなたのARSessionの変更されたIDを伝え、どのARAnchorがあなたのものかを追跡できるようにします。
            guard let multipeerSession = self.multipeerSession else { return }
            self.sendARSessionIDTo(peers: multipeerSession.connectedPeers)
        }
        
        // MultiPeerConnectivityで他のプレイヤーの検索を開始します。
        multipeerSession = MultipeerSession(serviceName: "multiuser-ar", receivedDataHandler: self.receivedData, peerJoinedHandler: self.peerJoined, peerLeftHandler: self.peerLeft, peerDiscoveredHandler: self.peerDiscovered)
    }
    
    @objc func handleTap(recognizer: UITapGestureRecognizer) {
        let anchor = ARAnchor(name: "LaserRed", transform: arView.cameraTransform.matrix)
        arView.session.add(anchor: anchor)
    }
    
    func placeObject(named entityName: String, for anchor: ARAnchor) {
        let laserEntity = try! ModelEntity.load(named: entityName)
        let anchorEntity = AnchorEntity(.anchor(identifier: anchor.identifier))
        anchorEntity.addChild(laserEntity)
        arView.scene.addAnchor(anchorEntity)
        
        // アニメーションは0.5秒で終わるので応急処置的に0.55秒後にアンカーを削除
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            self.arView.scene.removeAnchor(anchorEntity)
        }
    }
}

extension ViewController: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let anchorName = anchor.name, anchorName == "LaserRed" {
                placeObject(named: anchorName, for: anchor)
            }
            
            if let participantAnchor = anchor as? ARParticipantAnchor {
                print("他のユーザーとの接続に成功しました")
                
                let anchorEntity = AnchorEntity(anchor: participantAnchor)
                
                let mesh = MeshResource.generateSphere(radius: 0.03)
                let color = UIColor.red
                let material = SimpleMaterial(color: color, isMetallic: false)
                let coloredSphere = ModelEntity(mesh: mesh, materials: [material])
                
                anchorEntity.addChild(coloredSphere)
                
                arView.scene.addAnchor(anchorEntity)
            }
        }
    }
}

// MARK: - MultipeerSession

extension ViewController {
    private func sendARSessionIDTo(peers: [PeerID]) {
        guard let multipeerSession = multipeerSession else { return }
        let idString = arView.session.identifier.uuidString
        let command = "SessionID:" + idString
        if let commandData = command.data(using: .utf8) {
            multipeerSession.sendToPeers(commandData, reliably: true, peers: peers)
        }
    }
    
    func receivedData(_ data: Data, from peer: PeerID) {
        guard let multipeerSession = multipeerSession else { return }
        if let collaborationData = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARSession.CollaborationData.self, from: data) {
            arView.session.update(with: collaborationData)
            return
        }
        // ...
        let sessionIDCommandString = "SessionID:"
        if let commandString = String(data: data, encoding: .utf8), commandString.starts(with: sessionIDCommandString) {
            let newSessionID = String(commandString[commandString.index(commandString.startIndex,
                                                                        offsetBy: sessionIDCommandString.count)...])
            // この参加者が以前別のセッションIDを使用していた場合、関連するアンカーをすべて削除します。これにより、古い参加者アンカーとそのジオメトリがシーンから削除されます。
            if let oldSessionID = multipeerSession.peerSessionIDs[peer] {
                removeAllAnchorsOriginatingFromARSessionWithID(oldSessionID)
            }
            
            multipeerSession.peerSessionIDs[peer] = newSessionID
        }
    }
    
    // 5.7
    func peerDiscovered(_ peer: PeerID) -> Bool {
        guard let multipeerSession = multipeerSession else { return false }
        
        if multipeerSession.connectedPeers.count > 4 {
            // 4人以上のユーザーを体験で受け入れないこと。
            print("5人目のプレイヤーが参加したいと言っています。\nこのゲームは現在4人までとなっています。")
            return false
        } else {
            return true
        }
    }
    
    // 5.8
    func peerJoined(_ peer: PeerID) {
        print("プレイヤーがゲームに参加したい場合、デバイスを横に並べる。")
        // 新しいユーザーにあなたのセッションIDを提供し、あなたのアンカーを追跡できるようにします。
        sendARSessionIDTo(peers: [peer])
    }
    
    // 5.9
    func peerLeft(_ peer: PeerID) {
        guard let multipeerSession = multipeerSession else { return }
        
        print("プレイヤーがゲームから退出した。")
        
        // エクスペリエンスから抜けたピアに関連するすべてのARAnchorsを削除します。
        if let sessionID = multipeerSession.peerSessionIDs[peer] {
            removeAllAnchorsOriginatingFromARSessionWithID(sessionID)
            multipeerSession.peerSessionIDs.removeValue(forKey: peer)
        }
    }
    
    private func removeAllAnchorsOriginatingFromARSessionWithID(_ identifier: String) {
        guard let frame = arView.session.currentFrame else { return }
        for anchor in frame.anchors {
            guard let anchorSessionID = anchor.sessionIdentifier else { continue }
            if anchorSessionID.uuidString == identifier {
                arView.session.remove(anchor: anchor)
            }
        }
    }
    
    func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        guard let multipeerSession = multipeerSession else { return }
        if !multipeerSession.connectedPeers.isEmpty {
            guard let encodedData = try? NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)
            else { fatalError("コラボレーションデータのエンコードに予期せず失敗しました。") }
            // データが重要な場合は信頼できるモードを、データが任意である場合は信頼できないモードを使用します。
            let dataIsCritical = data.priority == .critical
            multipeerSession.sendToAllPeers(encodedData, reliably: dataIsCritical)
        } else {
            print("ピアがいないため、コラボレーションの送信を後回しにした。")
        }
    }
}
