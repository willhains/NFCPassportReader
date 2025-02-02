//
//  PassportReader.swift
//  NFCTest
//
//  Created by Andy Qua on 11/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import UIKit
import CoreNFC

public class PassportReader : NSObject {
    var dataGroupsToRead : [DataGroupId] = []

    var dataGroupsRead : [DataGroupId:DataGroup] = [:]
    
    public var passportMRZ : String {
        guard let dg1 = dataGroupsRead[.DG1] as? DataGroup1 else { return "NOT READ" }
        
        return "\(dg1.elements)"
    }
    public var passportImage : UIImage? {
        guard let dg2 = dataGroupsRead[.DG2] as? DataGroup2 else { return nil }
        
        return dg2.getImage()

    }
    public var signatureImage : UIImage? {
        guard let dg7 = dataGroupsRead[.DG7] as? DataGroup7 else { return nil }
        
        return dg7.getImage()
    }

    private var readerSession: NFCTagReaderSession?

    private var tagReader : TagReader?
    private var bacHandler : BACHandler?
    private var mrzKey : String = ""
    
    private var scanCompletedHandler: ((TagError?)->())!

    override public init( ) {
        super.init()
        
    }
    
    public func readPassport( mrzKey : String,  tags: [DataGroupId], completed: @escaping (TagError?)->() ) {
        self.mrzKey = mrzKey
        self.dataGroupsToRead.append( contentsOf:tags)
        self.scanCompletedHandler = completed
        
        guard NFCNDEFReaderSession.readingAvailable else {
            scanCompletedHandler( TagError.NFCNotSupported)
            return
        }
        
        if NFCTagReaderSession.readingAvailable {
            readerSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
            readerSession?.alertMessage = "Hold your iPhone near an NFC enabled passport."
            readerSession?.begin()
        }
    }
    
}


extension PassportReader : NFCTagReaderSessionDelegate {
    // MARK: - NFCTagReaderSessionDelegate
    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // If necessary, you may perform additional operations on session start.
        // At this point RF polling is enabled.
        Log.debug( "tagReaderSessionDidBecomeActive" )
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        // If necessary, you may handle the error. Note session is no longer valid.
        // You must create a new session to restart RF polling.
        Log.debug( "tagReaderSession:didInvalidateWithError - \(error)" )
        self.readerSession = nil
        
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Log.debug( "tagReaderSession:didDetect - \(tags[0])" )
        if tags.count > 1 {
            session.alertMessage = "More than 1 tags was found. Please present only 1 tag."
            return
        }
        
        let tag = tags.first!
        var passportTag: NFCISO7816Tag
        switch tags.first! {
        case let .iso7816(tag):
            passportTag = tag
        default:
            session.invalidate(errorMessage: "Tag not valid.")
            return
        }
        
        // Connect to tag
        session.connect(to: tag) { [unowned self] (error: Error?) in
            if error != nil {
                session.invalidate(errorMessage: "Connection error. Please try again.")
                return
            }
            
            self.readerSession?.alertMessage = "Authenticating with passport....."

            self.tagReader = TagReader(tag:passportTag)

            self.startReading( )

        }
    }
}


extension PassportReader {
    func startReading() {
        self.handleBAC(completed: { [weak self] error in
            if error == nil {
                // At this point, BAC Has been done and the TagReader has been set up with the SecureMessaging
                // session keys
                self?.readerSession?.alertMessage = "Reading passport data....."
                
                self?.readNextDataGroup( ) { [weak self] error in
                    if error != nil {
                        self?.readerSession?.invalidate(errorMessage: "Sorry, there was a problem reading the passport. Please try again" )
                    } else {
                        self?.readerSession?.invalidate()
                    }
                    self?.scanCompletedHandler( error )
                }
            } else {
                self?.readerSession?.invalidate(errorMessage: "Sorry, there was a problem reading the passport. Please try again" )
                self?.scanCompletedHandler(error)
            }
        })
    }
    
    func handleBAC( completed: @escaping (TagError?)->()) {
        guard let tagReader = self.tagReader else {
            completed(TagError.NoConnectedTag)
            return
        }
        
        self.bacHandler = BACHandler( tagReader: tagReader )
        bacHandler?.performBACAndGetSessionKeys( mrzKey: mrzKey ) { error in
            self.bacHandler = nil
            completed(error)
        }
    }
    
    func readNextDataGroup( completed : @escaping (TagError?)->() ) {
        guard let tagReader = self.tagReader else { completed(TagError.NoConnectedTag ); return }
        if dataGroupsToRead.count == 0 {
            completed(nil)
            return
        }
        
        let dgId = dataGroupsToRead.removeFirst()
        Log.info( "Reading tag - \(dgId)" )
        
        tagReader.readDataGroup(dataGroup:dgId) { [unowned self] (response, error) in
            if let response = response {
                do {
                    let dg = try DataGroupParser().parseDG(data: response)
                    self.dataGroupsRead[dgId] = dg
                } catch is TagError {
                    completed( error )
                } catch {
                    completed( TagError.UnexpectedError )
                }
                
                self.readNextDataGroup(completed: completed)
            } else {
                completed( error )
            }
        }
    }
}
