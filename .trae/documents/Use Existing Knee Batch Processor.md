I have identified that `backend/knee_batch_processor.py` is a specialized tool already present in your codebase that matches your requirements perfectly.

### **Existing Solution: Knee Batch Processor**
*   **Location**: `backend/knee_batch_processor.py`
*   **Capabilities**:
    *   **Batch Processing**: Automatically processes all videos in a specified directory.
    *   **Knee-Specific Metrics**: Calculates flexion angles, valgus/varus (injury risk), angular velocity/acceleration, and left/right asymmetry.
    *   **Wood Wide Integration**: Has built-in functionality to upload the resulting CSVs to the Wood Wide API.
    *   **Data Export**: Generates two CSVs:
        1.  `_metrics.csv`: Frame-by-frame detailed analysis.
        2.  `_summaries.csv`: Video-level summary stats (peaks, ROM, etc.).

### **Proposed Plan**
1.  **Verify Environment**: Ensure `WOODWIDE_AI_API_KEY` is set in your `.env` file or environment variables.
2.  **Usage Demonstration**: I will provide the command to run the batch processor on your video directory.
    ```bash
    python backend/knee_batch_processor.py /path/to/your/videos --upload --dataset-prefix my_knee_study
    ```
3.  **Execution**: If you have a folder of videos ready, I can run this command for you immediately.

Does this existing tool meet your needs, or would you like to modify the metrics it calculates?