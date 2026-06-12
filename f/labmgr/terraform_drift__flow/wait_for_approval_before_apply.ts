import * as wmill from "windmill-client";

export async function main() {
  const urls = await wmill.getResumeUrls("approver");
  return {
    message: "Approve terraform apply?",
    approvalPage: urls.approvalPage,
    resume: urls.resume,
    cancel: urls.cancel,
  };
}
