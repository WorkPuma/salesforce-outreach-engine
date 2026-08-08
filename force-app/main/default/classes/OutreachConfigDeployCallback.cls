public class OutreachConfigDeployCallback implements Metadata.DeployCallback {
  public void handleResult(
    Metadata.DeployResult result,
    Metadata.DeployCallbackContext context
  ) {
    // Fire-and-forget; LWC surfaces enqueue success. Failed deploys are visible in Setup Deployment Status.
    if (result == null || result.status == Metadata.DeployStatus.Succeeded)
      return;
    System.debug(
      LoggingLevel.ERROR,
      'Outreach config metadata deploy failed: ' +
      String.valueOf(result.status) +
      ' job=' +
      String.valueOf(result.id)
    );
  }
}
