import Foundation

func T(_ value: String) -> String { value }
let original: [String: Any] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.com/proxy.pac", "ExceptionsList": ["localhost"], "HTTPProxy": "old"]
let http = SystemProxyPreferences.proxyDictionary(original: original, host: "127.0.0.1", port: 7890, socks: false)
assert(http["HTTPEnable"] as? Int == 1 && http["HTTPSEnable"] as? Int == 1)
assert(http["HTTPSProxy"] as? String == "127.0.0.1" && http["HTTPSPort"] as? Int == 7890)
assert(http["SOCKSEnable"] as? Int == 0 && http["ProxyAutoConfigEnable"] as? Int == 0)
assert(http["ExceptionsList"] as? [String] == ["localhost"])
assert(original["HTTPProxy"] as? String == "old")
let socks = SystemProxyPreferences.proxyDictionary(original: http, host: "::1", port: 1080, socks: true)
assert(socks["SOCKSEnable"] as? Int == 1 && socks["HTTPEnable"] as? Int == 0 && socks["HTTPSEnable"] as? Int == 0)
assert(socks["SOCKSProxy"] as? String == "::1")
assert(SystemProxyPreferences.canRestore(current: http as NSDictionary, applied: http as NSDictionary, original: original as NSDictionary, existed: true))
assert(SystemProxyPreferences.canRestore(current: original as NSDictionary, applied: http as NSDictionary, original: original as NSDictionary, existed: true))
assert(!SystemProxyPreferences.canRestore(current: socks as NSDictionary, applied: http as NSDictionary, original: original as NSDictionary, existed: true))
assert(SystemProxyPreferences.canRestore(current: nil, applied: http as NSDictionary, original: [:], existed: false))
assert(!SystemProxyPreferences.canRestore(current: nil, applied: http as NSDictionary, original: original as NSDictionary, existed: true))
print("System proxy configuration and restore conflict checks passed")

let disabled = SystemProxyPreferences.directDictionary(original: http)
assert(disabled["HTTPEnable"] as? Int == 0 && disabled["HTTPSEnable"] as? Int == 0)
assert(disabled["ProxyAutoConfigEnable"] as? Int == 0 && disabled["SOCKSEnable"] as? Int == 0)
assert(disabled["ExceptionsList"] as? [String] == ["localhost"])
