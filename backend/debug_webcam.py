import cv2
import time
import sys

print("Initializing VideoCapture(0)...")
cap = cv2.VideoCapture(0)

if not cap.isOpened():
    print("ERROR: Could not open webcam.")
    sys.exit(1)

print("Webcam opened successfully.")
print("Reading 50 frames...")

cv2.namedWindow("Debug Webcam", cv2.WINDOW_NORMAL)

start_time = time.time()
for i in range(50):
    read_start = time.time()
    ret, frame = cap.read()
    read_end = time.time()
    
    if not ret:
        print(f"Frame {i}: Failed to read.")
        break
        
    print(f"Frame {i}: Read in {read_end - read_start:.4f}s")
    
    cv2.imshow("Debug Webcam", frame)
    key = cv2.waitKey(1)
    if key & 0xFF == ord('q'):
        print("Quitting...")
        break

end_time = time.time()
print(f"Finished. Total time: {end_time - start_time:.2f}s")

cap.release()
cv2.destroyAllWindows()
