# Brilliant Labs Frame - Realtime Gemini Voice and Vision Demo

Click on the images below, or on [this text to view the video](https://www.youtube.com/shorts/SliO6-i2b-w).

[![Realtime Usage](docs/image1.png)](https://www.youtube.com/shorts/SliO6-i2b-w)
[![Realtime UI](docs/image2.png)](https://www.youtube.com/shorts/SliO6-i2b-w)

Demonstrates the integration of a multimodal realtime assistant with [Brilliant Labs Frame](https://brilliant.xyz/).

In addition to audio streaming, the UI shows images that are streamed to the model, along with metadata about the conversation (turn taking and interruptions.)

The system prompt is editable to allow for customization of the assitant.

Each of the available Gemini Multimodal Live API voices (Puck, Charon, Kore, Fenrir, Aoede) are available for selection (the conversation needs to be restarted for a voice change to take effect.)

## Gemini API Setup

The realtime assistant is provided through the Google Gemini Multimodal Live API, and API keys (currently with a free usage tier) are available with registration: [See here](https://ai.google.dev/gemini-api/docs/api-key).

### 보안 API 키 관리 (Secure API Key Management)

이 앱은 API 키를 안전하게 관리하기 위한 여러 방법을 제공합니다:

1. **앱 내 저장**: API 키를 입력하면 앱 내 SharedPreferences에 안전하게 저장됩니다.

2. **apikey.env 파일 사용**: 프로젝트 루트에 `apikey.env` 파일을 생성하고 API 키만 입력하면 앱 시작 시 자동으로 로드됩니다:
   ```
   your_api_key_here
   ```
   이 파일은 `.gitignore`에 포함되어 있어 GitHub에 업로드되지 않습니다.

3. **마스킹 처리**: 앱 UI에서 API 키는 마스킹 처리되어 표시됩니다.

> ⚠️ **주의**: API 키를 소스 코드에 직접 하드코딩하지 마시고, GitHub 같은 공개 저장소에 업로드하지 마세요.

Add your API key in the text box at the top of the screen of the demo app and "Save".

Please note, API queries using the free usage tier can be used for training Google's models, but queries using paid keys should not. Refer to [Google's documentation](https://ai.google.dev/gemini-api/docs/multimodal-live) for details.

## Running the Demo

Grab your [Brilliant Labs Frame](https://brilliant.xyz/), then:
* Android: download and run the APK from [Releases](https://github.com/brilliantlabsAR/frame_realtime_gemini_voicevision/releases)
* iOS: clone, build and deploy to your iPhone using Flutter and Xcode from your Mac.

## 개발자를 위한 환경 설정 (Environment Setup for Developers)

1. 프로젝트를 클론합니다.
2. 프로젝트 루트에 `apikey.env` 파일을 생성하고 API 키만 입력합니다:
   ```
   AIzaSyBe0sZ7N3Fmt31J0_gfOOh29DeFJV2E4HU
   ```
3. 평소대로 Flutter 앱을 빌드하고 실행합니다.
