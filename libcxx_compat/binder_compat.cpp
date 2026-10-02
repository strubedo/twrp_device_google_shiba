// android::BBinder::setTransactionCodeMap for Android 16+ vendor binaries
// (citadeld, libnos_citadeld_proxy). New in A16's libbinder: registers
// human-readable names for a service's transaction codes, used only for
// debugging/tracing output. Our recovery's Android 14 libbinder lacks it.
// A no-op is safe: binder transactions themselves don't use the names.
// Declared minimally here (no libbinder headers needed); the mangled name
// matches libbinder's: _ZN7android7BBinder21setTransactionCodeMapEPKNS_19TransactionCodeDataE
namespace android {

struct TransactionCodeData;

class BBinder {
  public:
    void setTransactionCodeMap(const TransactionCodeData* data);
};

__attribute__((visibility("default")))
void BBinder::setTransactionCodeMap(const TransactionCodeData*) {}

}  // namespace android
