# Adopts the Maps key that a dfo-dev apply deleted and gcloud restored. Google
# keeps a deleted key's id reserved for 30 days, and the auth module names the
# key from random_id.api_key_suffix, which stayed in state, so Terraform must
# import the restored key rather than create it.
import {
  to = module.stack.module.auth.google_apikeys_key.maps_api_key[0]
  id = "projects/dev-fin-observatory/locations/global/keys/dfo-dev-dc-google-maps-key-f1c75504"
}
