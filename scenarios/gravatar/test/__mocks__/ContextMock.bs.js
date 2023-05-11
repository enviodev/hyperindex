// Generated by ReScript, PLEASE EDIT WITH CARE
'use strict';

var Sinon = require("../bindings/Sinon.bs.js");
var Sinon$1 = require("sinon");
var MockEntities = require("./MockEntities.bs.js");

var insertMock = Sinon$1.stub();

var updateMock = Sinon$1.stub();

var mockNewGravatarContext = {
  gravatar: {
    insert: (function (gravatarInsert) {
        Sinon.callStub1(insertMock, gravatarInsert.id);
      }),
    update: (function (gravatarUpdate) {
        Sinon.callStub1(updateMock, gravatarUpdate.id);
      }),
    delete: (function (_id) {
        console.log("inimplemented delete");
      })
  }
};

var mockUpdateGravatarContext = {
  gravatar: {
    gravatarWithChanges: (function (param) {
        return MockEntities.gravatarEntity1;
      }),
    insert: (function (gravatarInsert) {
        Sinon.callStub1(insertMock, gravatarInsert.id);
      }),
    update: (function (gravatarUpdate) {
        Sinon.callStub1(updateMock, gravatarUpdate.id);
      }),
    delete: (function (_id) {
        console.log("inimplemented delete");
      })
  }
};

exports.insertMock = insertMock;
exports.updateMock = updateMock;
exports.mockNewGravatarContext = mockNewGravatarContext;
exports.mockUpdateGravatarContext = mockUpdateGravatarContext;
/* insertMock Not a pure module */
