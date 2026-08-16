/// @file keychain.cpp
/// @brief Security.framework implementation of Keychain.

#include "mailengine/keychain.hpp"

#include "mailengine/identity.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#include <utility>

namespace mailengine {
namespace {

/// RAII owner for a Core Foundation object.
///
/// CF uses manual reference counting: anything from a `Create` or `Copy`
/// function must be `CFRelease`d. A guard makes that exception- and
/// early-return-safe, which matters because the Keychain calls below have
/// several failure paths.
template <typename T>
class CFRef {
 public:
  CFRef() = default;
  explicit CFRef(T ref) : ref_(ref) {}
  ~CFRef() {
    if (ref_ != nullptr) {
      CFRelease(ref_);
    }
  }
  CFRef(const CFRef&) = delete;
  CFRef& operator=(const CFRef&) = delete;
  CFRef(CFRef&& other) noexcept : ref_(std::exchange(other.ref_, nullptr)) {}

  /// Declaring a move constructor suppresses the implicit move assignment
  /// operator, and copy assignment is deleted — so without this, `ref = f()`
  /// fails to compile. Releases any existing object before taking the new one.
  CFRef& operator=(CFRef&& other) noexcept {
    if (this != &other) {
      if (ref_ != nullptr) {
        CFRelease(ref_);
      }
      ref_ = std::exchange(other.ref_, nullptr);
    }
    return *this;
  }

  [[nodiscard]] T get() const noexcept { return ref_; }
  /// Address-of for out-parameters such as SecItemCopyMatching's result.
  [[nodiscard]] T* put() noexcept { return &ref_; }

 private:
  T ref_ = nullptr;
};

/// Wraps a std::string as a CFStringRef without copying the bytes twice.
CFRef<CFStringRef> cf_string(const std::string& value) {
  return CFRef<CFStringRef>(CFStringCreateWithBytes(
      kCFAllocatorDefault, reinterpret_cast<const UInt8*>(value.data()),
      static_cast<CFIndex>(value.size()), kCFStringEncodingUTF8, false));
}

/// Translates an OSStatus into a readable error.
Error status_error(const std::string& what, OSStatus status) {
  CFRef<CFStringRef> message(SecCopyErrorMessageString(status, nullptr));
  std::string detail;
  if (message.get() != nullptr) {
    char buffer[512] = {};
    if (CFStringGetCString(message.get(), buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
      detail = buffer;
    }
  }
  return make_error(what + ": " + (detail.empty() ? "unknown" : detail),
                    static_cast<int>(status));
}

/// Builds the (class, service, account) triple identifying one item.
CFRef<CFMutableDictionaryRef> base_query(const std::string& service,
                                         const std::string& account,
                                         CFRef<CFStringRef>& service_ref,
                                         CFRef<CFStringRef>& account_ref) {
  service_ref = cf_string(service);
  account_ref = cf_string(account);

  CFRef<CFMutableDictionaryRef> query(CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks));

  CFDictionarySetValue(query.get(), kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(query.get(), kSecAttrService, service_ref.get());
  CFDictionarySetValue(query.get(), kSecAttrAccount, account_ref.get());
  return query;
}

}  // namespace

Keychain::Keychain(std::string service)
    : service_(service.empty() ? identity::keychain_service() : std::move(service)) {}

Result<void> Keychain::store(const std::string& account,
                             const std::string& secret) const {
  // Replace rather than merge: SecItemAdd fails with errSecDuplicateItem if an
  // entry already exists, and a re-auth should overwrite the old token.
  (void)remove(account);

  CFRef<CFStringRef> service_ref;
  CFRef<CFStringRef> account_ref;
  auto query = base_query(service_, account, service_ref, account_ref);

  CFRef<CFDataRef> data(CFDataCreate(
      kCFAllocatorDefault, reinterpret_cast<const UInt8*>(secret.data()),
      static_cast<CFIndex>(secret.size())));
  CFDictionarySetValue(query.get(), kSecValueData, data.get());

  // Available only once the device has been unlocked since boot, and never
  // synced to iCloud or included in backups.
  CFDictionarySetValue(query.get(), kSecAttrAccessible,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);

  const OSStatus status = SecItemAdd(query.get(), nullptr);
  if (status != errSecSuccess) {
    return status_error("SecItemAdd", status);
  }
  return {};
}

Result<std::string> Keychain::load(const std::string& account) const {
  CFRef<CFStringRef> service_ref;
  CFRef<CFStringRef> account_ref;
  auto query = base_query(service_, account, service_ref, account_ref);

  CFDictionarySetValue(query.get(), kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(query.get(), kSecMatchLimit, kSecMatchLimitOne);

  CFRef<CFTypeRef> result;
  const OSStatus status = SecItemCopyMatching(query.get(), result.put());
  if (status == errSecItemNotFound) {
    return make_error("no keychain item for account " + account,
                      static_cast<int>(status));
  }
  if (status != errSecSuccess) {
    return status_error("SecItemCopyMatching", status);
  }

  auto data = static_cast<CFDataRef>(result.get());
  if (data == nullptr) {
    return make_error("keychain item held no data");
  }
  return std::string(reinterpret_cast<const char*>(CFDataGetBytePtr(data)),
                     static_cast<size_t>(CFDataGetLength(data)));
}

Result<void> Keychain::remove(const std::string& account) const {
  CFRef<CFStringRef> service_ref;
  CFRef<CFStringRef> account_ref;
  auto query = base_query(service_, account, service_ref, account_ref);

  const OSStatus status = SecItemDelete(query.get());
  // Deleting something that was never there is a success from our perspective.
  if (status != errSecSuccess && status != errSecItemNotFound) {
    return status_error("SecItemDelete", status);
  }
  return {};
}

}  // namespace mailengine
