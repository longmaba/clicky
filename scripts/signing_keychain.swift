import Foundation
import Security

// Passwords arrive through stdin, never process arguments or build logs.
let request = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String:String]
let path = request["path"]!, password = Array(request["password"]!.utf8)
let create = request["operation"] == "create"
SecKeychainSetUserInteractionAllowed(false)
var keychain: SecKeychain?
func check(_ status: OSStatus) {
    guard status == errSecSuccess else {
        let message = SecCopyErrorMessageString(status,nil) as String? ?? "Security error \(status)"
        FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
    }
}
if create {
    check(password.withUnsafeBytes { SecKeychainCreate(path,UInt32($0.count),$0.baseAddress,false,nil,&keychain) })
} else {
    check(SecKeychainOpen(path,&keychain))
    check(password.withUnsafeBytes { SecKeychainUnlock(keychain,UInt32($0.count),$0.baseAddress,true) })
}
