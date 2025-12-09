using System;
using System.Threading.Tasks;
using Azure;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Azure.Communication;
using Azure.Communication.CallAutomation;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;

public class MakeCall
{
    [Function("MakeCall")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequestData req)
    {
        // input: { "to": "+44...", "from": "+1..." }
        var body = await req.ReadFromJsonAsync<CallRequest>();
        if (body == null || string.IsNullOrEmpty(body.To) || string.IsNullOrEmpty(body.From))
        {
            var bad = req.CreateResponse(System.Net.HttpStatusCode.BadRequest);
            await bad.WriteStringAsync("Request must include 'to' and 'from' phone numbers in E.164 format.");
            return bad;
        }

        // CONFIG: either set AcsConnectionString in local.settings.json for local testing
        // or set KEY_VAULT_URI and store secret 'AcsConnectionString' in Key Vault for production.
        string acsConn = Environment.GetEnvironmentVariable("AcsConnectionString");
        var kvUri = Environment.GetEnvironmentVariable("KEY_VAULT_URI");

        if (string.IsNullOrEmpty(acsConn) && !string.IsNullOrEmpty(kvUri))
        {
            try
            {
                var kv = new SecretClient(new Uri(kvUri), new DefaultAzureCredential());
                var secret = await kv.GetSecretAsync("AcsConnectionString");
                acsConn = secret.Value?.Value;
            }
            catch (RequestFailedException rf) when (rf.Status == 403)
            {
                // RBAC denied, fall back to env var if present
                acsConn = Environment.GetEnvironmentVariable("AcsConnectionString");
            }
            catch
            {
                acsConn = Environment.GetEnvironmentVariable("AcsConnectionString");
            }
        }

        if (string.IsNullOrEmpty(acsConn))
        {
            var err = req.CreateResponse(System.Net.HttpStatusCode.InternalServerError);
            await err.WriteStringAsync("AcsConnectionString missing. Set AcsConnectionString in local.settings.json or configure Key Vault.");
            return err;
        }

        // CALLBACK_URI must be a valid public HTTPS URL that ACS can reach. For local testing use webhook.site or ngrok.
        var callbackUri = Environment.GetEnvironmentVariable("CALLBACK_URI");
        if (string.IsNullOrWhiteSpace(callbackUri) || !Uri.TryCreate(callbackUri, UriKind.Absolute, out var cb) || cb.Scheme != Uri.UriSchemeHttps)
        {
            var err = req.CreateResponse(System.Net.HttpStatusCode.BadRequest);
            await err.WriteStringAsync("CALLBACK_URI must be set to a valid HTTPS URL. For local testing use a webhook service or ngrok HTTPS URL.");
            return err;
        }

        // create client and invite
        var client = new CallAutomationClient(acsConn);

        var invite = new CallInvite(
            new PhoneNumberIdentifier(body.To),    // destination
            new PhoneNumberIdentifier(body.From)   // source (your ACS phone number)
        );

        // CallAutomation requires a callbackUri. Provide the configured HTTPS url.
        Response<CreateCallResult> result;
        try
        {
            result = await client.CreateCallAsync(invite, callbackUri: new Uri(callbackUri));
        }
        catch (RequestFailedException rf)
        {
            var resp = req.CreateResponse(System.Net.HttpStatusCode.InternalServerError);
            await resp.WriteStringAsync($"ACS request failed: {rf.Message}");
            return resp;
        }

        var callId = result.Value?.CallConnectionProperties?.CallConnectionId ?? "no-call-id";
        var ok = req.CreateResponse(System.Net.HttpStatusCode.OK);
        await ok.WriteStringAsync(callId);
        return ok;
    }

    public class CallRequest
    {
        public string To { get; set; }
        public string From { get; set; }
    }
}



