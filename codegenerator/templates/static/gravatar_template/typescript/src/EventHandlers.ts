import {
  GravatarContract_registerNewGravatarHandler,
  GravatarContract_registerNewGravatarLoadEntities,
  GravatarContract_registerUpdatedGravatarHandler,
  GravatarContract_registerUpdatedGravatarLoadEntities,
} from "../generated/src/Handlers.gen";

import { gravatarEntity } from "../generated/src/Types.gen";

GravatarContract_registerNewGravatarLoadEntities(({ event, context }) => { });

GravatarContract_registerNewGravatarHandler(({ event, context }) => {
  let { id, displayName, owner, imageUrl } = event.params;
  let gravatar: gravatarEntity = {
    id: id.toString(),
    displayName,
    owner,
    imageUrl,
    updatesCount: 0,
  };
  context.gravatar.insert(gravatar);
});

GravatarContract_registerUpdatedGravatarLoadEntities(({ event, context }) => {
  context.gravatar.gravatarWithChangesLoad(event.params.id.toString());
});

GravatarContract_registerUpdatedGravatarHandler(({ event, context }) => {
  let { id, displayName, owner, imageUrl } = event.params;
  let currentUpdatesCount =
    context.gravatar.gravatarWithChanges()?.updatesCount ?? 0;

  let updatesCount = currentUpdatesCount + 1;

  let gravatar: gravatarEntity = {
    id: id.toString(),
    displayName,
    owner,
    imageUrl,
    updatesCount,
  };

  context.gravatar.update(gravatar);
});
