from aiortc.sdp import candidate_from_sdp

# Example candidate string (similar to what browsers send)
# Format: candidate:<foundation> <component> <protocol> <priority> <ip> <port> typ <type> ...
candidate_str = "candidate:842163049 1 udp 1677729535 127.0.0.1 5678 typ host generation 0"

try:
    print(f"Testing with raw string: '{candidate_str}'")
    candidate = candidate_from_sdp(candidate_str)
    print("Success! Parsed candidate:")
    print(f"  foundation: {candidate.foundation}")
    print(f"  component: {candidate.component}")
    print(f"  protocol: {candidate.protocol}")
    print(f"  priority: {candidate.priority}")
    print(f"  ip: {candidate.ip}")
    print(f"  port: {candidate.port}")
    print(f"  type: {candidate.type}")
except Exception as e:
    print(f"Failed with raw string: {e}")

# Test without "candidate:" prefix (just in case)
candidate_str_stripped = candidate_str.replace("candidate:", "")
try:
    print(f"\nTesting with stripped string: '{candidate_str_stripped}'")
    candidate = candidate_from_sdp(candidate_str_stripped)
    print("Success! Parsed candidate:")
    print(candidate)
except Exception as e:
    print(f"Failed with stripped string: {e}")
