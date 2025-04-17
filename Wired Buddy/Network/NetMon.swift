// Copyright (c) 2024 Jan Kowalewicz <jan@nitroosit.de>. Licensed under the MIT License.

import AppKit
import CoreWLAN
import Foundation
import Network
import OSLog

class WBNetworkMonitor: ObservableObject, CWEventDelegate {
    let networkMonitorInstance = NWPathMonitor()
    @Published var isWiredConnection: Bool = false
    @Published var isWiFiConnection: Bool = false {
        willSet {
            if newValue != isWiFiConnection, !isUpdatingFromSystem {
                logger.debug("WiFi toggle requested by user: \(newValue ? "ON" : "OFF")")
                toggleWiFi(enabled: newValue)
            }
        }
    }
    @Published var isPreferred: Bool = false
    @Published var ipAddr: String = ""
    @Published var interfaceName: String?

    private var wifiClient: CWWiFiClient?
    private let logger: Logger = Logger(
        subsystem: "de.jkowalewicz.WiredBuddy", category: "WiredBuddy_NWPathMonitor")
    private var isUpdatingFromSystem = false
    private var isTogglingWiFi = false

    init() {
        // Initialize Wi-Fi client
        wifiClient = CWWiFiClient.shared()

        // Set delegate to self to receive WiFi events
        wifiClient?.delegate = self

        start()
        setupWiFiMonitoring()

        // Initial check of WiFi power state
        updateWiFiPowerState()
    }

    deinit {
        stopWiFiMonitoring()
    }

    private func start() {
        networkMonitorInstance.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.isWiredConnection = self.isConnAvailable(in: path)

                // We'll handle WiFi power state separately
                // This only deals with wired network connectivity

                self.isPreferred = self.isConnPreferred(in: path)
                self.ipAddr = self.getIpAddr() ?? String(localized: "not_available")
            }
        }
        let q = DispatchQueue(label: "WiredBuddy_NWPathMonitor")
        networkMonitorInstance.start(queue: q)
    }

    private func setupWiFiMonitoring() {
        guard let client = wifiClient else { return }

        do {
            // Start monitoring power state changes
            try client.startMonitoringEvent(with: .powerDidChange)

            // Start monitoring link changes
            try client.startMonitoringEvent(with: .linkDidChange)

            // Start monitoring SSID changes
            try client.startMonitoringEvent(with: .ssidDidChange)

            // Initial update
            updateWiFiStatus()
        } catch {
            logger.error("Failed to start WiFi monitoring: \(error.localizedDescription)")
        }
    }

    private func stopWiFiMonitoring() {
        do {
            try wifiClient?.stopMonitoringAllEvents()
        } catch {
            logger.error("Failed to stop WiFi monitoring: \(error.localizedDescription)")
        }
    }

    // MARK: - WiFi Power State Management

    // Check and update the actual WiFi power state (enabled/disabled)
    private func updateWiFiPowerState() {
        guard let interface = wifiClient?.interface() else {
            logger.error("Could not get WiFi interface for power state check")
            return
        }

        let isPoweredOn = interface.powerOn()
        logger.debug("Checking WiFi power state: \(isPoweredOn ? "ON" : "OFF")")

        if isWiFiConnection != isPoweredOn {
            DispatchQueue.main.async {
                self.isUpdatingFromSystem = true
                self.isWiFiConnection = isPoweredOn
                self.isUpdatingFromSystem = false
            }
        }
    }

    // Toggle Wi-Fi on or off using CoreWLAN
    private func toggleWiFi(enabled: Bool) {
        guard let client = wifiClient, let interface = client.interface() else {
            logger.error("Could not get Wi-Fi interface")
            return
        }
        // Set flag to prevent feedback loops
        isTogglingWiFi = true

        do {
            // Get current state
            let currentState = interface.powerOn()
            logger.debug(
                "Current WiFi state: \(currentState ? "ON" : "OFF"), Setting to: \(enabled ? "ON" : "OFF")"
            )

            // Only toggle if state is different
            if currentState != enabled {
                // Use CoreWLAN to control Wi-Fi power
                try interface.setPower(enabled)
                logger.debug("WiFi power set to \(enabled ? "ON" : "OFF")")
            } else {
                logger.debug("WiFi is already \(enabled ? "ON" : "OFF"), skipping toggle")
                isTogglingWiFi = false
            }
        } catch {
            logger.error("Error toggling Wi-Fi: \(error.localizedDescription)")
            isTogglingWiFi = false
        }
    }

    // Finalize the WiFi toggle by checking actual state and releasing lock
    private func finalizeWiFiToggle() {
        // Get the actual power state and update if needed
        updateWiFiPowerState()

        // Release the toggle lock
        isTogglingWiFi = false
    }

    // MARK: - CWEventDelegate Methods

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        logger.debug("WiFi power state changed for interface: \(interfaceName)")
        // Only update from system events if we're not manually toggling
        if !isTogglingWiFi {
            updateWiFiPowerState()
        }
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        logger.debug("WiFi link state changed for interface: \(interfaceName)")
        // Link changes don't affect power state
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        logger.debug("WiFi SSID changed for interface: \(interfaceName)")
        // SSID changes don't affect power state
    }

    // Update Wi-Fi status using CoreWLAN
    private func updateWiFiStatus() {
        guard let client = wifiClient, let interface = client.interface() else {
            return
        }

        // Skip if we're in the middle of toggling
        if isTogglingWiFi {
            logger.debug("Skipping WiFi status update while toggle is in progress")
            return
        }

        // Get current power state directly from CoreWLAN
        let isPoweredOn = interface.powerOn()
        logger.debug("updateWiFiStatus: CoreWLAN reports WiFi is \(isPoweredOn ? "ON" : "OFF")")

        // For the toggle, we only care about the power state
        if isWiFiConnection != isPoweredOn {
            logger.debug("Updating UI to match WiFi state: \(isPoweredOn ? "ON" : "OFF")")

            DispatchQueue.main.async {
                self.isUpdatingFromSystem = true
                self.isWiFiConnection = isPoweredOn
                self.isUpdatingFromSystem = false
            }
        }
    }

    private func isConnAvailable(in path: NWPath) -> Bool {
        if path.status == .satisfied {
            // Network is available, but is it wired?
            if path.usesInterfaceType(.wiredEthernet) {
                logger.debug("path=satisfied,conntype=wired")
                return true
            } else {
                logger.debug("path=satisfied,conntype=other")
                return false
            }
        } else {
            // Network status unsatisfied
            logger.error("path=unsatisfied,conntype=unknown")
            return false
        }
    }

    private func isWiFiAvailable(in path: NWPath) -> Bool {
        if path.status == .satisfied {
            // Check if Wi-Fi is being used
            if path.usesInterfaceType(.wifi) {
                logger.debug("path=satisfied,conntype=wifi")
                return true
            } else {
                logger.debug("path=satisfied,conntype=not_wifi")
                return false
            }
        } else {
            logger.error("path=unsatisfied,conntype=unknown")
            return false
        }
    }

    // Checks if our connection is the preferred interface.
    private func isConnPreferred(in path: NWPath) -> Bool {
        if path.status == .satisfied {
            // Network is available, is it wired?
            if path.usesInterfaceType(.wiredEthernet) {
                // Are we a preferred interface?
                let first = path.availableInterfaces.first
                if isInterfaceWired(path: path, interfaceName: first?.name ?? "") {
                    interfaceName = first!.name
                    logger.debug(
                        "Interface name for active ethernet session: \(self.interfaceName!)")
                    return true
                } else {
                    interfaceName = nil
                    return false
                }
            } else {
                interfaceName = nil
                return false
            }
        } else {
            interfaceName = nil
            return false
        }
    }

    // Checks if a specific interface is wired or not
    private func isInterfaceWired(path: NWPath, interfaceName: String) -> Bool {
        if let interface = path.availableInterfaces.first(where: { $0.name == interfaceName }) {
            if interface.type == .wifi {
                logger.error("\(interfaceName) is wifi")
                return false
            } else if interface.type == .wiredEthernet {
                logger.debug("\(interfaceName) is ethernet / wired")
                return true
            }
        }
        logger.debug("\(interfaceName) is unknown")
        return false
    }

    // Returns the current used IP address
    public func getIpAddr() -> String? {
        var addr: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return nil
        }
        guard let firstAddr = ifaddr else {
            return nil
        }

        for iface_ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let iface = iface_ptr.pointee
            let family = iface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) /* || family == UInt8(AF_INET6)*/ {
                let name = String(cString: iface.ifa_name)
                if interfaceName != nil {
                    if name == interfaceName {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(
                            iface.ifa_addr, socklen_t((iface.ifa_addr.pointee.sa_len)), &hostname,
                            socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        addr = String(cString: hostname)
                        freeifaddrs(ifaddr)
                        return addr
                    }
                }
            }
        }
        freeifaddrs(ifaddr)

        return addr
    }
}
