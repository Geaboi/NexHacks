import numpy as np
import sys
import os

# Add backend to path to import handler
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'backend')))

# Mock the handler class to test just the alignment logic
class MockHandler:
    def align_signals(self, imu_data, cv_velocities, cv_timestamps_ms):
        # reuse the logic from the actual file or import it if possible
        # Since I can't easily import the class without dependencies (cv2, onnx), I will copy the logic here for unit testing the math.
        
        # LOGIC START
        imu_timestamps = []
        imu_values = []
        
        for s in imu_data:
            imu_timestamps.append(s['timestamp_ms'])
            w_rel = s['data']['value'] # specific to test format
            imu_values.append(w_rel)
            
        imu_timestamps = np.array(imu_timestamps)
        imu_values = np.array(imu_values)
        
        # Grid definition
        step_ms = 10
        # For test, define max time cover both
        max_time = max(imu_timestamps[-1], cv_timestamps_ms[-1])
        common_time = np.arange(0, max_time, step_ms)
        
        # Interpolate
        imu_interp = np.interp(common_time, imu_timestamps, imu_values)
        cv_interp = np.interp(common_time, cv_timestamps_ms, cv_velocities)
        
        # Normalize
        if np.std(imu_interp) > 1e-5:
            imu_norm = (imu_interp - np.mean(imu_interp)) / np.std(imu_interp)
        else:
            imu_norm = imu_interp
            
        if np.std(cv_interp) > 1e-5:
            cv_norm = (cv_interp - np.mean(cv_interp)) / np.std(cv_interp)
        else:
            cv_norm = cv_interp

        # Correlation
        correlation = np.correlate(imu_norm, cv_norm, mode='full')
        lags = np.arange(-len(imu_norm) + 1, len(cv_norm))
        
        peak_idx = np.argmax(correlation)
        peak_lag_idx = lags[peak_idx]
        offset_ms = peak_lag_idx * step_ms
        max_corr = correlation[peak_idx] / len(common_time)
        
        return offset_ms, max_corr

def test_alignment():
    print("Testing Alignment Logic...")
    handler = MockHandler()
    
    # 1. Create a base signal (Gaussian pulse)
    t = np.linspace(0, 2000, 200) # 0 to 2000ms
    signal_base = np.exp(-((t - 1000)**2) / (2 * 100**2)) # Peak at 1000ms
    
    # 2. Case A: CV is DELAYED by 500ms relative to IMU
    # Real Event at 1000ms.
    # IMU records at T=1000ms.
    # CV records at T=500ms (because CV started 500ms LATE, so its T=0 is RealT=500).
    # So CV signal should appear at T=500 in CV time?
    # Real Time of Peak = 1000.
    # IMU Time of Peak = 1000.
    # CV Time of Peak = 1000 - 500 = 500.
    
    # IMU Data
    imu_data = [{'timestamp_ms': time, 'data': {'value': val}} for time, val in zip(t, signal_base)]
    
    # CV Data (shifted LEFT by 500ms)
    delay_ms = 500
    cv_t = t
    cv_signal = np.exp(-((cv_t + delay_ms - 1000)**2) / (2 * 100**2)) # Peak at 500ms
    
    offset, corr = handler.align_signals(imu_data, cv_signal, cv_t)
    
    print(f"Expected Lag: ~{delay_ms} ms (IMU peak at 1000, CV peak at 500)")
    print(f"Calculated Offset: {offset} ms")
    
    # We define alignment as: IMU(t) matches CV(t - offset)?
    # If offset is positive, it means we shift CV to RIGHT to match IMU?
    # Or shift IMU to LEFT?
    # My logic in handler: `offset_ms = peak_lag_idx * step_ms`.
    # `correlate(imu, cv)`.
    # Peak at lag L means `imu[k] matches cv[k+L]`.
    # `imu[100] (peak)` matches `cv[50+L]`.
    # `cv` peak is at 50. `imu` peak is at 100.
    # So `cv[50]` is high. `imu[100]` is high.
    # We want `k` such that `imu[k]` matches `cv[k+L]`?
    # `imu[100] ~ cv[50]`.
    # So `100 = 50 + L` => `L = 50`.
    # So Lag should be +50 steps = +500 ms.
    # Correct.
    
    if abs(offset - 500) < 20: 
        print("PASS: Alignment correct.")
    else:
        print("FAIL: Alignment incorrect.")

if __name__ == "__main__":
    test_alignment()
