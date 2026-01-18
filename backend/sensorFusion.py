import numpy as np


CV_CONFIDENCE_CUTOFF = 0.3
VARIANCE_BIAS = 16

# Reuse the exact same FusionEKF class from before!
# The math (Prediction/Correction) doesn't care that the input is a difference.
class FusionEKF:
    def __init__(self, initial_angle=0.0):
        self.x = np.array([initial_angle, 0.0]) # [Joint Angle, Differential Bias]
        self.P = np.diag([5.0, 1.0])
        self.Q = np.diag([0.005, 0.001])  # Tuned for relative motion
        
    def predict(self, relative_gyro_deg_s, dt):
        angle = self.x[0]
        bias = self.x[1]
        
        # Prediction: New Joint Angle = Old + (Relative Gyro - Relative Bias) * dt
        new_angle = angle + (relative_gyro_deg_s - bias) * dt
        
        self.x[0] = new_angle
        
        # Jacobian F (same as before)
        F = np.array([[1.0, -dt], [0.0,  1.0]])
        self.P = F @ self.P @ F.T + self.Q
        
    def update(self, cv_angle, cv_confidence):
        if cv_confidence < CV_CONFIDENCE_CUTOFF:
            return self.x[0]
        
        base_R = VARIANCE_BIAS
        dynamic_R = base_R / (cv_confidence + 1e-3)
        R_matrix = np.array([[dynamic_R]])
        
        H = np.array([[1.0, 0.0]])
        y = cv_angle - self.x[0]
        S = H @ self.P @ H.T + R_matrix
        K = self.P @ H.T @ np.linalg.inv(S)
        self.x = self.x + (K.flatten() * y)
        I = np.eye(2)
        self.P = (I - np.outer(K, H)) @ self.P
        return self.x[0]
    
