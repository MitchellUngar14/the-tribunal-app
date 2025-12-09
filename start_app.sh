#!/bin/bash

# Ensure TRIBUNAL_API_KEY is set in backend/.env file

echo "Starting Tribunal Backend..."
npm --prefix "backend" run dev &
BACKEND_PID=$!

echo "Starting Tribunal Frontend..."
npm --prefix "frontend-app" start &
FRONTEND_PID=$!

echo "Backend PID: $BACKEND_PID"
echo "Frontend PID: $FRONTEND_PID"
echo "To stop the applications, you can use 'kill $BACKEND_PID' and 'kill $FRONTEND_PID' or close the terminal."

wait $BACKEND_PID
wait $FRONTEND_PID
