import 'package:simple_frame_app/simple_frame_app.dart';
import 'device_interface.dart';
import 'frame_device.dart';
import 'mobile_device.dart';

class DeviceFactory {
  static DeviceInterface createDevice(SimpleFrameAppState? frameState) {
    if (frameState != null && frameState.frame != null) {
      return FrameDevice(frameState);
    }

    // Frame이 없으면 모바일 디바이스 사용
    return MobileDevice();
  }
}
