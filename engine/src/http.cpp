/// @file http.cpp
/// @brief libcurl-backed implementation of HttpClient.

#include "mailengine/http.hpp"

#include <curl/curl.h>

#include <utility>

namespace mailengine {
namespace {

/// libcurl write callback. Appends received bytes to a std::string.
///
/// The signature is fixed by libcurl: (ptr, size, nmemb, userdata). `size` is
/// always 1 in practice, but multiplying is the documented contract. Returning
/// anything other than the full byte count signals an error to curl and aborts
/// the transfer.
size_t append_to_string(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* out = static_cast<std::string*>(userdata);
  const size_t bytes = size * nmemb;
  out->append(ptr, bytes);
  return bytes;
}

/// RAII owner for curl's linked-list header type.
///
/// curl_slist_append allocates, and the list must outlive the transfer but be
/// freed after it. A guard type removes every early-return leak.
class HeaderList {
 public:
  void add(const std::string& header) {
    list_ = curl_slist_append(list_, header.c_str());
  }
  ~HeaderList() {
    if (list_ != nullptr) {
      curl_slist_free_all(list_);
    }
  }
  HeaderList() = default;
  HeaderList(const HeaderList&) = delete;
  HeaderList& operator=(const HeaderList&) = delete;

  [[nodiscard]] curl_slist* get() const noexcept { return list_; }

 private:
  curl_slist* list_ = nullptr;
};

}  // namespace

HttpClient::HttpClient() {
  handle_ = curl_easy_init();
}

HttpClient::~HttpClient() {
  if (handle_ != nullptr) {
    curl_easy_cleanup(static_cast<CURL*>(handle_));
  }
}

HttpClient::HttpClient(HttpClient&& other) noexcept
    : handle_(std::exchange(other.handle_, nullptr)),
      timeout_seconds_(other.timeout_seconds_) {}

HttpClient& HttpClient::operator=(HttpClient&& other) noexcept {
  if (this != &other) {
    if (handle_ != nullptr) {
      curl_easy_cleanup(static_cast<CURL*>(handle_));
    }
    handle_ = std::exchange(other.handle_, nullptr);
    timeout_seconds_ = other.timeout_seconds_;
  }
  return *this;
}

Result<HttpResponse> HttpClient::perform(
    const std::string& url,
    const std::map<std::string, std::string>& headers) {
  auto* curl = static_cast<CURL*>(handle_);
  if (curl == nullptr) {
    return make_error("curl handle not initialised");
  }

  std::string body;
  HeaderList header_list;
  for (const auto& [name, value] : headers) {
    header_list.add(name + ": " + value);
  }

  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append_to_string);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds_);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  // Without a timeout AND this, a stalled transfer can hang indefinitely.
  // CURLOPT_TIMEOUT alone does not cover a body-read that never produces data.
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
  // libcurl uses signals for DNS timeouts by default, which is unsafe once the
  // ingest pool is multi-threaded.
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  // Certificate verification stays on. Google's endpoints hold real certs and
  // there is never a reason to disable this.
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(curl, CURLOPT_USERAGENT, "mailengine/0.1");
  if (header_list.get() != nullptr) {
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list.get());
  }

  const CURLcode code = curl_easy_perform(curl);
  if (code != CURLE_OK) {
    return make_error(curl_easy_strerror(code), static_cast<int>(code));
  }

  long status = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

  // Header list is freed by HeaderList's destructor, so drop curl's pointer to
  // it before that happens.
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, nullptr);

  return HttpResponse{status, std::move(body)};
}

Result<HttpResponse> HttpClient::get(
    const std::string& url,
    const std::map<std::string, std::string>& headers) {
  auto* curl = static_cast<CURL*>(handle_);
  if (curl == nullptr) {
    return make_error("curl handle not initialised");
  }
  // Clears options left over from a previous request — notably POST body state,
  // which would otherwise turn this GET into a POST. Live connections, the TLS
  // session cache and the DNS cache all survive a reset, so the performance
  // reason for reusing the handle is preserved.
  curl_easy_reset(curl);
  curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
  return perform(url, headers);
}

Result<HttpResponse> HttpClient::post(
    const std::string& url,
    const std::string& body,
    const std::string& content_type,
    const std::map<std::string, std::string>& headers) {
  auto* curl = static_cast<CURL*>(handle_);
  if (curl == nullptr) {
    return make_error("curl handle not initialised");
  }
  curl_easy_reset(curl);

  auto with_type = headers;
  with_type["Content-Type"] = content_type;

  curl_easy_setopt(curl, CURLOPT_POST, 1L);
  // ORDER MATTERS. CURLOPT_POSTFIELDSIZE must be set BEFORE
  // CURLOPT_COPYPOSTFIELDS: the copy uses the already-known size, and setting
  // the size afterwards invalidates the copied buffer. libcurl then falls back
  // to its default read callback — which reads from STDIN — and the process
  // blocks forever inside curl_easy_perform with an established connection and
  // no request body. That failure looks like a network hang and is not.
  curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
  // COPYPOSTFIELDS copies the buffer, so `body` need not outlive the call.
  curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, body.data());

  return perform(url, with_type);
}

std::string HttpClient::url_encode(const std::string& value) {
  // curl_easy_escape needs a handle but does not perform I/O; a throwaway is
  // fine and avoids requiring an HttpClient instance for a pure function.
  CURL* curl = curl_easy_init();
  if (curl == nullptr) {
    return value;
  }
  char* escaped = curl_easy_escape(curl, value.c_str(), static_cast<int>(value.size()));
  std::string result = (escaped != nullptr) ? escaped : value;
  if (escaped != nullptr) {
    curl_free(escaped);
  }
  curl_easy_cleanup(curl);
  return result;
}

std::string HttpClient::form_encode(
    const std::vector<std::pair<std::string, std::string>>& fields) {
  std::string out;
  for (const auto& [key, value] : fields) {
    if (!out.empty()) {
      out += '&';
    }
    out += url_encode(key);
    out += '=';
    out += url_encode(value);
  }
  return out;
}

}  // namespace mailengine
