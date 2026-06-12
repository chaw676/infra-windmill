// Final rollup — stand-in for the ADO build-page summary. Wire a
// Teams/Slack webhook call here when drift is true (the ADO YAML
// listed that as a wishlist item).
export async function main(tf: any, action: string) {
  if (action === "apply") {
    return { status: "applied", pets: tf?.pets };
  }
  if (tf?.drift) {
    return { status: "DRIFT_DETECTED", plan: tf.plan_text };
  }
  return { status: "clean" };
}
