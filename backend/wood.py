import pandas as pd
import numpy as np

num_timesteps = 1000
t = np.arange(num_timesteps)  # time index

np.random.seed(42)

angles_list = np.column_stack([
    t,
    30 + 15 * np.sin(t / 10) + np.random.normal(0, 1.5, num_timesteps),
    30 + 15 * np.sin(t / 10 + 0.1) + np.random.normal(0, 1.5, num_timesteps),
    25 + 10 * np.sin(t / 10 + 0.2) + np.random.normal(0, 1.2, num_timesteps),
    25 + 10 * np.sin(t / 10 + 0.3) + np.random.normal(0, 1.2, num_timesteps),
    15 + 8 * np.sin(t / 10 + 0.4) + np.random.normal(0, 1.0, num_timesteps),
    15 + 8 * np.sin(t / 10 + 0.5) + np.random.normal(0, 1.0, num_timesteps)
])

df = pd.DataFrame(
    angles_list,
    columns=[
        "time",
        "left_knee_flexion",
        "right_knee_flexion",
        "left_hip_flexion",
        "right_hip_flexion",
        "left_ankle_flexion",
        "right_ankle_flexion"
    ]
)

df.to_csv("joint_angles_timeseries.csv", index=False)
