//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
        
        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = BoringNotchXPCHelper()
        newConnection.exportedObject = exportedObject
        
        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

/// The app streams now playing information through a Perl script that only notices its parent
/// is gone the next time it writes, so a crashed app could leave it running forever.
/// Each launch of the helper clears such orphans.
func stopOrphanedMediaAdapters() {
    guard let output = Command.run("/bin/ps", ["-axo", "pid=,ppid=,args="]) else { return }
    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count == 3, fields[1] == "1", fields[2].contains("mediaremote-adapter.pl"),
              fields[2].contains("MediaRemoteAdapter.framework"), let pid = pid_t(fields[0])
        else { continue }
        kill(pid, SIGTERM)
    }
}

DispatchQueue.global(qos: .utility).async(execute: stopOrphanedMediaAdapters)

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
