//
//  BluetoothManager.swift
//  ChunkTimerPeri
//
//  Created by Jay Tucker on 6/30/15.
//  Copyright (c) 2015 Imprivata. All rights reserved.
//

import UIKit
import CoreBluetooth

class BluetoothManager: NSObject {
    
    private let serviceUUID                = CBUUID(string: "193DB24F-E42E-49D2-9A70-6A5616863A9D")
    private let requestCharacteristicUUID  = CBUUID(string: "43CDD5AB-3EF6-496A-A4CC-9933F5ADAF68")
    private let responseCharacteristicUUID = CBUUID(string: "F1A9A759-C922-4219-B62C-1A14F62DE0A4")
    
    private var peripheralManager: CBPeripheralManager!
    private var responseCharacteristic: CBMutableCharacteristic!
    private var isPoweredOn = false
    
    private let dechunker = Dechunker()
    
    private let chunkSize = 19
    private var pendingResponseChunks = Array< Array<UInt8> >()
    private var nChunks = 0
    private var nChunksSent = 0
    
    private var startTime = NSDate()
    
    private var uiBackgroundTaskIdentifier: UIBackgroundTaskIdentifier!
    
    /*
    dispatch_queue_create("responseChunkQueue", DISPATCH_QUEUE_SERIAL)
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
    */
    
    private let responseChunkQueue = dispatch_queue_create("responseChunkQueue", DISPATCH_QUEUE_SERIAL)
    
    // See:
    // http://stackoverflow.com/questions/24218581/need-self-to-set-all-constants-of-a-swift-class-in-init
    // http://stackoverflow.com/questions/24441254/how-to-pass-self-to-initializer-during-initialization-of-an-object-in-swift
    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    private func addService() {
        log("addService")
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        let service = CBMutableService(type: serviceUUID, primary: true)
        let requestCharacteristic = CBMutableCharacteristic(
            type: requestCharacteristicUUID,
            properties: CBCharacteristicProperties.WriteWithoutResponse,
            value: nil,
            permissions: CBAttributePermissions.Writeable)
        responseCharacteristic = CBMutableCharacteristic(
            type: responseCharacteristicUUID,
            properties: CBCharacteristicProperties.Notify,
            value: nil,
            permissions: CBAttributePermissions.Readable)
        service.characteristics = [requestCharacteristic, responseCharacteristic]
        peripheralManager.addService(service)
    }
    
    private func startAdvertising() {
        log("startAdvertising")
        peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }
    
    private func nameFromUUID(uuid: CBUUID) -> String {
        switch uuid {
        case serviceUUID: return "service"
        case requestCharacteristicUUID: return "requestCharacteristic"
        case responseCharacteristicUUID: return "responseCharacteristic"
        default: return "unknown"
        }
    }
    
    private func processRequest(requestBytes: [UInt8]) {
//        let request = String(bytes: requestBytes, encoding: NSUTF8StringEncoding)!
//        let response = request
//        var responseBytes = [UInt8]()
//        for codeUnit in response.utf8 {
//            responseBytes.append(codeUnit)
//        }
        pendingResponseChunks = Chunker.makeChunks(requestBytes, chunkSize: chunkSize)
        nChunks = pendingResponseChunks.count
        nChunksSent = 0
        log("pending response \(requestBytes.count) bytes (\(nChunks) chunks of \(chunkSize) bytes)")
        
        let delay = 20.0
        
        dispatch_async(responseChunkQueue) {
            self.beginBackgroundTask()
            
            let delayStr = String(format: "%.3f", delay)
            log("will send response in \(delayStr) secs")
            
            let timer = NSTimer.scheduledTimerWithTimeInterval(delay, target: self, selector: "sendNextResponseChunk", userInfo: nil, repeats: false)
            NSRunLoop.currentRunLoop().addTimer(timer, forMode: NSDefaultRunLoopMode)
            NSRunLoop.currentRunLoop().run()
        }
    }
    
    func sendNextResponseChunk() {
        if nChunksSent == 0 {
            startTime = NSDate()
        }
        let chunk = pendingResponseChunks[nChunksSent]
        log("sending chunk \(nChunksSent + 1)/\(nChunks) (\(pendingResponseChunks[nChunksSent].count) bytes)")
        let chunkData = NSData(bytes: chunk, length: chunk.count)
        let isSuccess = peripheralManager.updateValue(chunkData, forCharacteristic: responseCharacteristic, onSubscribedCentrals: nil)
        // log("isSuccess \(isSuccess)")
        if isSuccess {
            nChunksSent++
            if nChunksSent < nChunks {
                dispatch_async(responseChunkQueue) {
                    self.sendNextResponseChunk()
                }
            } else {
                let timeInterval = startTime.timeIntervalSinceNow
                log("all chunks sent in \(-timeInterval) secs")
                pendingResponseChunks.removeAll(keepCapacity: false)
                nChunks = 0
                nChunksSent = 0
                self.endBackgroundTask()
            }
        } else {
            log("send failed, wait for BTLE callback")
        }
    }
    
    private func calculateDelay() -> Double {
        log("calculateDelay")
        let now = NSDate()
        var ti = now.timeIntervalSinceReferenceDate
        
        // round up to next send interval
        let sendInterval = 30.0
        ti = ti - (ti % sendInterval) + sendInterval
        let sendTime = NSDate(timeIntervalSinceReferenceDate: ti)
        
        let dateFormatter = NSDateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        log("now  \(dateFormatter.stringFromDate(now))")
        log("send \(dateFormatter.stringFromDate(sendTime))")
        
        let delay = sendTime.timeIntervalSinceDate(now)
        return delay
    }
    
    private func beginBackgroundTask() {
        log("beginBackgroundTask")
        uiBackgroundTaskIdentifier = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler {
            self.endBackgroundTaskExpirationHandler()
        }
        log("uiBackgroundTaskIdentifier \(uiBackgroundTaskIdentifier)")
        backgroundTimeRemaining()
    }
    
    private func endBackgroundTask() {
        log("endBackgroundTask")
        log("uiBackgroundTaskIdentifier \(uiBackgroundTaskIdentifier)")
        backgroundTimeRemaining()
        UIApplication.sharedApplication().endBackgroundTask(uiBackgroundTaskIdentifier)
        uiBackgroundTaskIdentifier = UIBackgroundTaskInvalid
    }
    
    private func endBackgroundTaskExpirationHandler() {
        log("endBackgroundTaskExpirationHandler")
        log("uiBackgroundTaskIdentifier \(uiBackgroundTaskIdentifier)")
        backgroundTimeRemaining()
        UIApplication.sharedApplication().endBackgroundTask(uiBackgroundTaskIdentifier)
        uiBackgroundTaskIdentifier = UIBackgroundTaskInvalid
    }
    
    private func backgroundTimeRemaining() {
        let backgroundTimeRemaining = UIApplication.sharedApplication().backgroundTimeRemaining
        log("backgroundTimeRemaining \(backgroundTimeRemaining)")
    }
    
}

extension BluetoothManager: CBPeripheralManagerDelegate {
    
    func peripheralManagerDidUpdateState(peripheralManager: CBPeripheralManager!) {
        var caseString: String!
        switch peripheralManager.state {
        case .Unknown:
            caseString = "Unknown"
        case .Resetting:
            caseString = "Resetting"
        case .Unsupported:
            caseString = "Unsupported"
        case .Unauthorized:
            caseString = "Unauthorized"
        case .PoweredOff:
            caseString = "PoweredOff"
        case .PoweredOn:
            caseString = "PoweredOn"
        default:
            caseString = "WTF"
        }
        log("peripheralManagerDidUpdateState \(caseString)")
        isPoweredOn = (peripheralManager.state == .PoweredOn)
        if isPoweredOn {
            addService()
        }
    }
    
    func peripheralManager(peripheral: CBPeripheralManager!, didAddService service: CBService!, error: NSError!) {
        var message = "peripheralManager didAddService \(nameFromUUID(service.UUID)) \(service.UUID) "
        if error == nil {
            message += "ok"
            log(message)
            startAdvertising()
        } else {
            message = "error " + error.localizedDescription
            log(message)
        }
    }
    
    func peripheralManagerDidStartAdvertising(peripheral: CBPeripheralManager!, error: NSError!) {
        var message = "peripheralManagerDidStartAdvertising "
        if error == nil {
            message += "ok"
        } else {
            message = "error " + error.localizedDescription
        }
        log(message)
    }
    
    func peripheralManager(peripheral: CBPeripheralManager!, central: CBCentral!, didSubscribeToCharacteristic characteristic: CBCharacteristic!) {
        log("peripheralManager didSubscribeToCharacteristic \(nameFromUUID(characteristic.UUID))")
    }
    
    func peripheralManager(peripheral: CBPeripheralManager!, didReceiveWriteRequests requests: [AnyObject]!) {
        log("peripheralManager didReceiveWriteRequests \(requests.count)")
        if requests.count == 0 {
            return
        }
        let request = requests[0] as! CBATTRequest
        
        log("request received (\(request.value.length) bytes)")
        
        var chunkBytes = [UInt8](count: request.value.length, repeatedValue: 0)
        request.value.getBytes(&chunkBytes, length: request.value.length)
        let retval = dechunker.addChunk(chunkBytes)
        if retval.isSuccess {
            if let finalResult = retval.finalResult {
                log("dechunker done")
                log("received \(finalResult.count) bytes from dechunker")
                processRequest(finalResult)
            } else {
                // chunk was ok, but more to come
                log("dechunker ok, but not done yet")
            }
        } else {
            // chunk was faulty
            log("dechunker failed")
        }
    }
    
    func peripheralManagerIsReadyToUpdateSubscribers(peripheral: CBPeripheralManager!) {
        log("peripheralManagerIsReadyToUpdateSubscribers")
        dispatch_async(responseChunkQueue) {
            self.sendNextResponseChunk()
        }
    }
    
}
