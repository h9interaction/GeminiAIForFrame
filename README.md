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

Add your API key in the text box at the top of the screen of the demo app and "Save".

Please note, API queries using the free usage tier can be used for training Google's models, but queries using paid keys should not. Refer to [Google's documentation](https://ai.google.dev/gemini-api/docs/multimodal-live) for details.

## Running the Demo

Grab your [Brilliant Labs Frame](https://brilliant.xyz/), then:
* Android: download and run the APK from [Releases](https://github.com/brilliantlabsAR/frame_realtime_gemini_voicevision/releases)
* iOS: clone, build and deploy to your iPhone using Flutter and Xcode from your Mac.
