import Foundation
import IOKit
import IOUSBHost
import Network

/// Connects paired Android phones over a USB cable with Android Open Accessory (AOA), without developer mode.
///
/// When an Android phone is plugged in and no paired phone is online over Wi-Fi, Glimpse switches the phone to
/// accessory mode. Android then asks the user to open Glimpse for Android, which opens the link (`UsbLink.kt`).
/// The link only carries bytes: each local connection to `127.0.0.1:<port>` becomes a stream to the phone's own
/// HTTPS server. TLS, the pinned certificates and the API stay the same as on Wi-Fi.
final class UsbAccessoryWatcher: @unchecked Sendable {
    static let shared = UsbAccessoryWatcher()

    /// Google's accessory IDs. 0x2D01 also has adb, and 0x2D02 to 0x2D05 have audio.
    static let accessoryVendor = 0x18D1
    static let accessoryProducts = 0x2D00...0x2D05

    private let queue = DispatchQueue(label: "Glimpse.USB")
    private var notifications: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var links: [UInt64: UsbLink] = [:]
    /// When each device got the switch request, so a phone without the app is not asked again and again.
    private var switched: [String: Date] = [:]

    func start() {
        queue.async { [self] in
            guard notifications == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            notifications = port
            IONotificationPortSetDispatchQueue(port, queue)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { context, iterator in
                Unmanaged<UsbAccessoryWatcher>.fromOpaque(context!).takeUnretainedValue().added(iterator)
            }, context, &iterator)
            // A phone that is plugged in at launch gets time to connect over Wi-Fi first (a hello every 30 s).
            added(iterator, after: 35)
        }
    }

    private func added(_ iterator: io_iterator_t, after delay: TimeInterval = 1) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vendor = Self.property(service, "idVendor") ?? 0
            let product = Self.property(service, "idProduct") ?? 0
            // The interfaces appear a moment after the device.
            queue.asyncAfter(deadline: .now() + (vendor == Self.accessoryVendor ? 1 : delay)) { [self] in
                defer { IOObjectRelease(service) }
                if vendor == Self.accessoryVendor && Self.accessoryProducts.contains(product) {
                    attach(service)
                } else if vendor != 0x05AC, Self.looksLikeAndroid(service), shouldSwitch(service) {
                    switchToAccessory(service)
                }
            }
        }
    }

    /// Switch only when a paired phone needs the cable: no paired phone is online over Wi-Fi.
    private func shouldSwitch(_ service: io_service_t) -> Bool {
        if let last = switched[Self.serial(service)], Date().timeIntervalSince(last) < 60 { return false }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let library = DeviceLibrary.shared
                return !library.phones.isEmpty && !library.phones.contains(where: library.isOnline)
            }
        }
    }

    // MARK: - Switching to accessory mode

    private func switchToAccessory(_ service: io_service_t) {
        switched[Self.serial(service)] = Date()
        // macOS or adb often holds the device itself; a free interface can send the same requests.
        let objects: [IOUSBHostObject] = [(try? IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: nil))].compactMap { $0 }
            + Self.interfaces(of: service).compactMap { try? IOUSBHostInterface(__ioService: $0, options: [], queue: queue, interestHandler: nil) }
        defer { objects.forEach { $0.destroy() } }
        for object in objects {
            guard let version = Self.protocolVersion(object), version >= 1 else { continue }
            let strings = ["Glimpse", "Glimpse for Mac", "Browse this phone in Glimpse on your Mac", "1.0",
                           "https://github.com/jiunshinn/glimpse", "0"]
            for (index, text) in strings.enumerated() {
                let data = NSMutableData(data: Data(text.utf8) + [0])
                let request = IOUSBDeviceRequest(bmRequestType: 0x40, bRequest: 52, wValue: 0, wIndex: UInt16(index),
                                                 wLength: UInt16(data.length))
                guard (try? object.__send(request, data: data, bytesTransferred: nil, completionTimeout: 2)) != nil else { return }
            }
            let start = IOUSBDeviceRequest(bmRequestType: 0x40, bRequest: 53, wValue: 0, wIndex: 0, wLength: 0)
            _ = try? object.__send(start, data: nil, bytesTransferred: nil, completionTimeout: 2)
            return
        }
    }

    private static func protocolVersion(_ object: IOUSBHostObject) -> Int? {
        let request = IOUSBDeviceRequest(bmRequestType: 0xC0, bRequest: 51, wValue: 0, wIndex: 0, wLength: 2)
        let data = NSMutableData(length: 2)!
        var count: UInt = 0
        guard (try? object.__send(request, data: data, bytesTransferred: &count, completionTimeout: 2)) != nil, count == 2 else { return nil }
        let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
        return Int(bytes[0]) | Int(bytes[1]) << 8
    }

    // MARK: - Accessory mode

    private func attach(_ service: io_service_t) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        guard links[id] == nil,
              let interface = Self.interfaces(of: service).first(where: { Self.property($0, "bInterfaceNumber") == 0 }) else { return }
        do {
            let link = try UsbLink(interface: interface, queue: queue) { [weak self] in
                self?.queue.async { self?.links[id] = nil }
            }
            links[id] = link
            link.start()
        } catch {
            NSLog("Glimpse USB: could not open the accessory: \(error)")
        }
    }

    // MARK: - IOKit helpers

    private static func property(_ service: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? Int
    }

    private static func serial(_ service: io_service_t) -> String {
        let serial = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, nil, 0)?.takeRetainedValue() as? String
        return "\(property(service, "idVendor") ?? 0):\(serial ?? "\(property(service, "locationID") ?? 0)")"
    }

    private static func interfaces(of device: io_service_t) -> [io_service_t] {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }
        var result: [io_service_t] = []
        while case let child = IOIteratorNext(children), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 { result.append(child) } else { IOObjectRelease(child) }
        }
        return result
    }

    /// An MTP or PTP interface, or an adb interface. iPhones are left out by their vendor ID.
    private static func looksLikeAndroid(_ device: io_service_t) -> Bool {
        interfaces(of: device).contains { interface in
            defer { IOObjectRelease(interface) }
            let kind = (property(interface, "bInterfaceClass"), property(interface, "bInterfaceSubClass"), property(interface, "bInterfaceProtocol"))
            return kind == (6, 1, 1) || kind == (0xFF, 0x42, 0x01) || kind == (0xFF, 0xFF, 0)
        }
    }
}

/// One accessory link: the bulk pipes to the phone, and a local port whose connections go through them.
/// The frame format must stay the same as `UsbLink.kt` on the phone.
final class UsbLink: @unchecked Sendable {
    static let header = 9
    static let readSize = 16 * 1024
    static let maxPayload = readSize - 2 * header
    static let packet = 512

    enum Frame: UInt8 {
        case noop = 0, open = 1, data = 2, close = 3, hello = 16
    }

    struct Failure: Error {}

    private let queue: DispatchQueue
    private let writer = DispatchQueue(label: "Glimpse.USB.write")
    private let interface: IOUSBHostInterface
    private let input: IOUSBHostPipe
    private let output: IOUSBHostPipe
    private var listener: NWListener?
    private var streams: [UInt32: NWConnection] = [:]
    private var nextStream: UInt32 = 1
    private var pending = Data()
    private var deviceID: String?
    private var closed = false
    private let onClose: () -> Void

    init(interface service: io_service_t, queue: DispatchQueue, onClose: @escaping () -> Void) throws {
        self.queue = queue
        self.onClose = onClose
        var closeLink: (() -> Void)?
        interface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue) { _, type, _ in
            // kIOMessageServiceIsTerminated: the cable was pulled, or the phone left accessory mode.
            if type == 0xE000_0010 { closeLink?() }
        }
        IOObjectRelease(service)
        var bulkIn: Int?, bulkOut: Int?
        let configuration = interface.configurationDescriptor
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(configuration, interface.interfaceDescriptor, current) {
            if endpoint.pointee.bmAttributes & 0x3 == 2 {  // Bulk
                let address = Int(endpoint.pointee.bEndpointAddress)
                if address & 0x80 != 0 { bulkIn = address } else { bulkOut = address }
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let bulkIn, let bulkOut else { throw Failure() }
        input = try interface.copyPipe(withAddress: bulkIn)
        output = try interface.copyPipe(withAddress: bulkOut)
        closeLink = { [weak self] in self?.close() }
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return close() }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.announce() }
        }
        listener.start(queue: queue)
        read()
    }

    func close() {
        guard !closed else { return }
        closed = true
        listener?.cancel()
        streams.values.forEach { $0.cancel() }
        streams.removeAll()
        interface.destroy()
        if let deviceID {
            DispatchQueue.main.async { MainActor.assumeIsolated { DeviceLibrary.shared.usbDetached(deviceID) } }
        }
        onClose()
    }

    /// The phone said who it is, and the local port is ready: the device library can use the cable now.
    private func announce() {
        guard let deviceID, let port = listener?.port?.rawValue else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { DeviceLibrary.shared.usbAttached(deviceID, port: Int(port)) } }
    }

    // MARK: - Local connections

    private func accept(_ connection: NWConnection) {
        let stream = nextStream
        nextStream += 2
        streams[stream] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.send(stream, .open)
                self?.pump(stream, connection)
            case .failed, .cancelled:
                self?.endStream(stream, notify: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func pump(_ stream: UInt32, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxPayload) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.send(stream, .data, data) }
            if isComplete || error != nil {
                self.endStream(stream, notify: true)
            } else {
                self.pump(stream, connection)
            }
        }
    }

    private func endStream(_ stream: UInt32, notify: Bool) {
        guard let connection = streams.removeValue(forKey: stream) else { return }
        connection.cancel()
        if notify { send(stream, .close) }
    }

    // MARK: - USB

    private func read() {
        guard !closed, let buffer = NSMutableData(length: Self.readSize) else { return }
        do {
            try input.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, count in
                guard let self else { return }
                guard status == kIOReturnSuccess else { return self.close() }
                self.consume(Data(bytes: buffer.bytes, count: count))
                self.read()
            }
        } catch {
            close()
        }
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while pending.count >= Self.header {
            let bytes = [UInt8](pending.prefix(Self.header))
            let stream = bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let length = Int(bytes[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length <= Self.readSize else { return close() }
            guard pending.count >= Self.header + length else { break }
            let payload = pending.subdata(in: pending.startIndex + Self.header..<pending.startIndex + Self.header + length)
            pending.removeFirst(Self.header + length)
            handle(stream, Frame(rawValue: bytes[4]), payload)
        }
    }

    private func handle(_ stream: UInt32, _ type: Frame?, _ payload: Data) {
        switch type {
        case .hello:
            let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            deviceID = json?["id"] as? String
            if listener?.port != nil { announce() }
        case .data:
            streams[stream]?.send(content: payload, completion: .contentProcessed { _ in })
        case .close:
            endStream(stream, notify: false)
        case .open, .noop, nil:
            break
        }
    }

    private func send(_ stream: UInt32, _ type: Frame, _ payload: Data = Data()) {
        var frame = Data(capacity: Self.header * 2 + payload.count)
        frame.append(contentsOf: withUnsafeBytes(of: stream.bigEndian, Array.init))
        frame.append(type.rawValue)
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        frame.append(payload)
        // A write that fills whole USB packets would wait on the phone for more bytes. A short padding frame ends it.
        if frame.count % Self.packet == 0 { frame.append(contentsOf: [0, 0, 0, 0, Frame.noop.rawValue, 0, 0, 0, 0]) }
        writer.async { [weak self] in
            guard let self, !self.closed else { return }
            let data = NSMutableData(data: frame)
            if (try? self.output.__sendIORequest(with: data, bytesTransferred: nil, completionTimeout: 10)) == nil {
                self.queue.async { self.close() }
            }
        }
    }
}
