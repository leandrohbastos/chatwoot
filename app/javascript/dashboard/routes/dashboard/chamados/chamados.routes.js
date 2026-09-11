import { frontendURL } from '../../../helper/URLHelper';
import ChamadosIndex from './Index.vue';

export const routes = [
  {
    path: frontendURL('accounts/:accountId/chamados'),
    name: 'chamados_dashboard',
    meta: {
      permissions: ['administrator', 'agent', 'custom_role'],
    },
    component: ChamadosIndex,
  },
];
