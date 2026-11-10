import Foundation

protocol LogitechRequestTransport: AnyObject {
    func transact(feature: UInt8, function: UInt8, parameters: [UInt8], deviceIndex: UInt8) throws -> [UInt8]
}

extension LogitechHIDTransport: LogitechRequestTransport {
    func transact(feature: UInt8, function: UInt8, parameters: [UInt8], deviceIndex: UInt8) throws -> [UInt8] {
        try request(feature: feature, function: function, parameters: parameters, deviceIndex: deviceIndex)
    }
}
