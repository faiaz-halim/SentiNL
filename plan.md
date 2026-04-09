# Project Implementation Plan & Architecture: SentiNL (On-Device Scam Detector)

This document outlines the actual, finalized implementation of the SentiNL Flutter application and Python backend, which deploys a locally fine-tuned Gemma 4 LLM for on-device scam detection.

## System Architecture
*   **Mobile App (Frontend):** Flutter (Android 10+). Uses `google_mlkit_text_recognition` for on-device OCR, `sqflite` for local offline knowledge base, and a local LLM binding (`llamadart` v0.6.10) to run the `Q4_K_M` GGUF model natively via `llama.cpp`.
*   **AI Model:** Gemma 4 (2B), instruction fine-tuned locally on AMD Strix Halo APU hardware (ROCm) using `bfloat16` and standard Hugging Face PEFT/TRL pipelines, then exported to GGUF format.
*   **Backend Server:** Python/FastAPI running on a local PC (`uvicorn`). Provides endpoints for OTA SQLite database updates and a cloud fallback search using `ddgs` (DuckDuckGo) for real-time threat verification.

---

## Phase 1: Dataset Prep & Local Model Fine-Tuning (AMD Strix Halo)
*Due to Colab free-tier limitations and the user's massive 128GB Unified Memory APU, training was migrated entirely to local hardware.*

1.  **Dataset Preparation:** A robust Python pipeline automatically aggregates four distinct Hugging Face datasets: `ucirvine/sms_spam`, `notd5a/sms-malicious-benign-dataset`, `zefang-liu/phishing-email-dataset`, and `kmack/Phishing_urls`. It formats over 20,500 diverse rows of SMS, Smishing, Email Phishing, and URL data into the exact Chat Template required by Gemma.
2.  **AMD Hardware Overrides:** To prevent ROCm 6.2 segfaults on the RDNA 3.5 architecture, the environment is spoofed (`HSA_OVERRIDE_GFX_VERSION="11.0.0"`, `HSA_ENABLE_SDMA="0"`).
3.  **Fine-Tuning:** Uses a custom `finetune_hf_toolbox.py` script running inside a patched Podman toolbox. It uses `AutoModelForCausalLM` with `attn_implementation="eager"` to bypass Triton flash-attention crashes.
4.  **Export:** The LoRA adapter is merged via `PeftModel` and converted to `Q4_K_M` using a locally compiled CMake build of `llama.cpp`.

---

## Phase 2: Backend API Development
**Objective:** Create a Python API to serve blacklist updates and perform web searches for the cloud fallback.
**Tech Stack:** Python, FastAPI, `ddgs`, `uvicorn`.

### Step 2.1: DB Update & Static File Endpoint
*   **Implementation:** Serves a dynamic `blacklist.json` containing known threats.
*   **Static Hosting:** Hosts the massive 3.2GB `.gguf` file via FastAPI `StaticFiles` so the mobile app can pull it securely over the local network.

### Step 2.2: Cloud Fallback Endpoint (`/api/verify`)
*   **Implementation:** Uses the `ddgs` package to query DuckDuckGo.
*   **Rate-Limit Fix:** To prevent the Python server from freezing due to DDG bot-blocking, a strict `timeout=10` is applied.
*   **Smart Querying:** The backend uses Regex to extract the first URL from the OCR text to search. If no URL exists, it truncates the search to the first 100 characters to prevent 0-result crashes from massive text blocks.

---

## Phase 3: Flutter App Core & UI
**Objective:** Build an accessible, senior-friendly Flutter UI with robust error handling.

### Step 3.1: App Skeleton & Accessibility UI
*   **Implementation:** Built `HomeScreen` with a Yellow/Black high-contrast theme.
*   **Scrolling Fix:** The entire view is wrapped in a `SingleChildScrollView` to prevent nested scrolling locks.
*   **Markdown Support:** Uses `flutter_markdown` so the AI's explanation renders bolding and bullet points perfectly.

### Step 3.2: Security & Minification Overrides
*   **Cleartext Traffic:** Android 9+ blocks `http://`. Added `usesCleartextTraffic="true"` to `AndroidManifest.xml` to allow local Wi-Fi backend communication.
*   **R8 Minifier Fix:** Added `-dontwarn com.google.mlkit.vision.text.**` to `proguard-rules.pro` to prevent the release compiler from crashing over missing Asian-language ML Kit dependencies.

---

## Phase 4: AI & OCR Pipeline (Flutter)
**Objective:** Combine OCR, Local DB checking, and Local LLM inference.

### Step 4.1: OCR Integration
*   **Implementation:** Uses `image_picker` and `google_mlkit_text_recognition` to grab screenshots and extract text locally.

### Step 4.2: Model Provisioning & Wakelocks
*   **Model Storage:** Uses `getExternalStorageDirectory()` so developers can quickly bypass Wi-Fi and push the 3GB model over USB via `adb push`.
*   **Download Engine:** If downloading over Wi-Fi, `Dio` is configured with a 2-hour timeout. `wakelock_plus` is used to prevent the Android OS from turning off the screen/Wi-Fi radio mid-download.
*   **Corruption Check:** A strict `file.lengthSync() < 3000000000` check deletes the `.gguf` file if the download aborts early.

### Step 4.3: The Analysis Workflow Integration
*   **Inference Function:** Uses `llamadart` 0.6.10. `ChatSession.create()` streams the tokens asynchronously to the UI.
*   **Output Parsing:** 
    1.  **Thinking Process Filter:** Gemma models often leak `<|channel>thought`. A strict custom Regex scans the output backward and strictly substrings from the final `- Threat level:` to completely silence the hallucinated thinking logs.
    2.  **Threat Level Parser:** Only checks the very first line of the parsed response for the word "danger" or "caution", preventing the UI from defaulting to "Danger" if the word "scam" appears normally in the explanation.

---

## Phase 5: Environment & Deployment
*   **Git Security:** Hardcoded IP addresses were stripped. The app uses `--dart-define=BACKEND_URL` and `--dart-define=MODEL_URL` at compile time to inject server IPs safely.
*   **Clean Repository:** A strict `.gitignore` ensures that the 10GB `model.safetensors`, `.gguf` files, Python environments, and Flutter build caches are kept out of version control.
