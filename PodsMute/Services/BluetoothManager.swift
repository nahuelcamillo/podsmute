//
//  BluetoothManager.swift
//  PodsMute
//
//  Manages Bluetooth device detection for AirPods status display.
//  Supports AirPods Max and AirPods Pro.
//  Uses IOBluetooth to check actual connection status.
//

import Foundation
import Combine
import IOBluetooth

// MARK: - Connection State

/// Connection state for AirPods
enum ConnectionState: Int {
    case disconnected = 0
    case connecting = 1
    case connected = 2

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        }
    }

    var isConnected: Bool {
        return self == .connected
    }
}

// MARK: - Device Info

/// Information about a paired AirPods device
struct AirPodsDevice: Identifiable {
    let id: String  // Bluetooth address
    let name: String
    let isConnected: Bool
}

// MARK: - Bluetooth Manager

/// Manages Bluetooth device detection for AirPods.
///
/// Supports AirPods Max and AirPods Pro.
/// Uses IOBluetooth to detect paired devices and check their connection status.
final class BluetoothManager: ObservableObject {

    // MARK: - Published Properties

    /// Current connection state
    @Published private(set) var connectionState: ConnectionState = .disconnected

    /// Name of the connected device (nil if not connected)
    @Published private(set) var connectedDeviceName: String?

    // MARK: - Private Properties

    private var statusCheckTimer: Timer?

    /// All IOBluetooth calls run here. The CoreBluetooth coordinator's first
    /// init can block on a semaphore (notably under the LaunchAgent context),
    /// which would freeze the main thread / app launch if called there.
    private let btQueue = DispatchQueue(label: "ar.daten.podsmute.bluetooth", qos: .utility)

    // MARK: - Computed Properties

    /// Convenience property for connection status
    var isConnected: Bool {
        connectionState.isConnected
    }

    // MARK: - Initialization

    init() {
        // Check initial connection status
        checkConnectionStatus()

        // Start periodic status checking
        startStatusMonitoring()
    }

    deinit {
        stopStatusMonitoring()
    }

    // MARK: - Status Monitoring

    private func startStatusMonitoring() {
        // Check connection status every 2 seconds
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkConnectionStatus()
        }
    }

    private func stopStatusMonitoring() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
    }

    /// Check actual Bluetooth connection status of AirPods.
    /// IOBluetooth runs off the main thread; results are published on main.
    func checkConnectionStatus() {
        btQueue.async { [weak self] in
            guard let self = self else { return }
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            var connectedName: String?
            for device in devices {
                guard let name = device.name, self.isSupportedAirPods(name: name) else { continue }
                if device.isConnected() { connectedName = name; break }
            }
            self.updateState(connected: connectedName != nil, deviceName: connectedName)
        }
    }

    private func updateState(connected: Bool, deviceName: String?) {
        DispatchQueue.main.async {
            let newState: ConnectionState = connected ? .connected : .disconnected

            if self.connectionState != newState || self.connectedDeviceName != deviceName {
                self.connectionState = newState
                self.connectedDeviceName = deviceName

                if connected {
                    print("[BluetoothManager] AirPods connected: \(deviceName ?? "Unknown")")
                } else {
                    print("[BluetoothManager] AirPods disconnected")
                }
            }
        }
    }

    // MARK: - Device Discovery

    /// Get list of paired AirPods devices (Max and Pro)
    func pairedDevices() -> [AirPodsDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        return devices.compactMap { device -> AirPodsDevice? in
            guard let name = device.name, isSupportedAirPods(name: name) else {
                return nil
            }

            let address = device.addressString ?? "Unknown"
            return AirPodsDevice(
                id: address,
                name: name,
                isConnected: device.isConnected()
            )
        }
    }

    /// Get the first paired AirPods device
    func firstPairedDevice() -> AirPodsDevice? {
        return pairedDevices().first
    }

    // MARK: - Helper Methods

    /// Check if a device name indicates a supported AirPods device (Max or Pro)
    private func isSupportedAirPods(name: String) -> Bool {
        let lowercaseName = name.lowercased()
        return lowercaseName.contains("airpods max") || lowercaseName.contains("airpods pro")
    }

    // MARK: - Public Methods

    /// Refresh connection status (for manual refresh from UI)
    func refreshStatus() {
        checkConnectionStatus()
    }

    /// No-op for compatibility - we use Darwin notifications now
    @discardableResult
    func autoConnectToPairedDevice() -> Bool {
        checkConnectionStatus()
        return isConnected
    }
}
