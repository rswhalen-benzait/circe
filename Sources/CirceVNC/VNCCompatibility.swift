/// Shared identity for the RFB compatibility transport. The native Circe transport
/// remains the default; explicit vnc:// addresses select this compatibility path.
public enum VNCCompatibility {
    public static let protocolVersion = "RFB 003.008\n"
    public static let defaultPort: UInt16 = 5900
    public static let appleRemoteDesktopSecurityType: UInt8 = 30
}
