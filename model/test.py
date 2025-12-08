import cv2
import numpy as np
import tensorflow as tf
import tensorflow.lite as tflite
import matplotlib.pyplot as plt

# --- user params ---
MODEL_PATH = "MiDaS.tflite"
IMG_PATH = "dog2.jpg"
TARGET_HW = (256, 256)   # (height, width) expected by your script

# --- load image and basic preprocessing ---
img_bgr = cv2.imread(IMG_PATH)
if img_bgr is None:
    raise FileNotFoundError(f"Can't load {IMG_PATH}")
orig_h, orig_w = img_bgr.shape[:2]

img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
# resize using OpenCV (faster and deterministic)
img_resized = cv2.resize(img_rgb, (TARGET_HW[1], TARGET_HW[0]), interpolation=cv2.INTER_CUBIC)
img_resized = img_resized.astype(np.float32) / 255.0

# normalize with ImageNet mean/std (MiDaS often expects this)
mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
std  = np.array([0.229, 0.224, 0.225], dtype=np.float32)
img_norm = (img_resized - mean) / std  # shape (H,W,3)

# --- load tflite model and inspect details ---
interpreter = tflite.Interpreter(model_path=MODEL_PATH)
interpreter.allocate_tensors()
input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

print("Input details:", input_details)
print("Output details:", output_details)

# choose input dtype and shape
in_idx = input_details[0]['index']
in_shape = input_details[0]['shape'].copy()   # e.g. [1,256,256,3] or [1,3,256,256]
in_dtype = input_details[0]['dtype']
# quantization params
scale, zero_point = input_details[0].get('quantization', (0.0, 0))

# prepare input array with correct shape & dtype
# detect channel ordering: if shape is (1,3,H,W) -> channels_first
if in_shape[1] == 3 and in_shape[2] == TARGET_HW[0] and in_shape[3] == TARGET_HW[1]:
    # channels_first
    input_data = np.transpose(img_norm, (2, 0, 1))  # (3,H,W)
    input_data = np.expand_dims(input_data, axis=0) # (1,3,H,W)
elif in_shape[1] == TARGET_HW[0] and in_shape[2] == TARGET_HW[1] and in_shape[3] == 3:
    # channels_last
    input_data = np.expand_dims(img_norm, axis=0)   # (1,H,W,3)
else:
    # fallback: try to reshape to interpreter's expected spatial dims
    # This will usually fail if incompatible; keep original channels-last as best effort
    input_data = np.expand_dims(img_norm, axis=0)

# handle quantization if needed
if in_dtype == np.uint8 or (scale and zero_point):
    if scale == 0:
        # If scale==0 in details, attempt to infer scale by checking dtype
        scale = 1.0
        zero_point = 0
    input_data_q = (input_data / scale + zero_point).round().astype(np.uint8)
    interpreter.set_tensor(in_idx, input_data_q)
else:
    interpreter.set_tensor(in_idx, input_data.astype(np.float32))

# --- run inference ---
interpreter.invoke()

# --- read and postprocess output ---
out_idx = output_details[0]['index']
output_data = interpreter.get_tensor(out_idx)  # numpy
print("raw output shape:", output_data.shape, "dtype:", output_data.dtype)

# common output shapes: (1, H, W, 1) or (1,1,H,W) or (1,H,W)
out = np.squeeze(output_data)  # reduce dims, result should be 2D (H, W)
if out.ndim != 2:
    # try to extract channel 0 if present
    out = out[..., 0] if out.shape[-1] == 1 else out.squeeze()

# resize to original image size
prediction = cv2.resize(out.astype(np.float32), (orig_w, orig_h), interpolation=cv2.INTER_CUBIC)

# normalize depth map for visualization (0-255)
dmin, dmax = prediction.min(), prediction.max()
if dmax - dmin > 1e-6:
    vis = (255 * (prediction - dmin) / (dmax - dmin)).astype(np.uint8)
else:
    vis = (prediction * 0).astype(np.uint8)

cv2.imwrite("output.png", vis)          # note: saved as grayscale
print("Wrote output.png")
plt.figure(figsize=(8,8))
plt.imshow(vis, cmap='gray')
plt.axis('off')
plt.show()
